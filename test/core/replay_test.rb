# frozen_string_literal: true
require_relative '../test_helper'
class ReplayTest < CoreTest
  def fixture(*steps, secrets: [])
    sink = StringIO.new
    recorder = Expect4r::Diagnostics::Recording.new(sink, session_id: 'fixture', label: nil)
    secrets.each { |secret| recorder.redact(secret) }
    steps.each do |kind, bytes|
      if [:rx, :tx].include?(kind)
        recorder.io(kind, bytes)
      else
        recorder.event({ session_id: 'fixture', event: kind, error_class: bytes })
      end
    end
    recorder.finish(complete: true)
    StringIO.new(sink.string)
  end
  def altered(source)
    rows = source.string.lines.map { |line| JSON.parse(line) }
    yield rows
    StringIO.new(rows.map { |row| JSON.generate(row) + "\n" }.join)
  end
  def test_dialogue_replays_under_original_and_one_byte_fragmentation
    [nil, 1, 3].each do |fragment_size|
      trace = fixture([:rx, 'ready>'], [:tx, "go\r"], [:rx, "a\0\xffEND".b], [:eof])
      Expect4r.replay(trace, fragment_size:, buffer_limit: 8, require_all_reads: true) do |session|
        assert_equal 'ready>', session.expect!('ready>').match
        session.send_line('go')
        result = session.capture_until!('END', retain: nil)
        assert_equal "a\0\xff".b, result.output
        assert session.expect!(:eof).eof?
        assert session.verify_replay!(require_all_reads: true)
      end
    end
  end
  def test_actual_socket_recording_round_trips
    sink = StringIO.new
    with_input('ready>', recording: sink) do |session, peer|
      session.expect!('ready>')
      session.write("go\r")
      assert_equal "go\r", peer.read(3)
      peer.write('ackEND')
      peer.close_write
      assert_equal 'ack', session.capture_until!('END').output
      session.expect!(:eof)
    end
    Expect4r.replay(StringIO.new(sink.string), fragment_size: 1, require_all_reads: true) do |session|
      session.expect!('ready>')
      session.write("go\r")
      assert_equal 'ack', session.capture_until!('END').output
      assert session.expect!(:eof).eof?
    end
  end
  def test_write_call_boundaries_can_be_split_or_coalesced
    trace = fixture([:tx, 'a'], [:tx, 'bc'], [:tx, 'd'], [:eof])
    Expect4r.replay(trace, require_all_reads: true) do |session|
      assert_equal 4, session.write('abcd')
      session.expect!(:eof)
    end
    Expect4r.replay(fixture([:tx, 'abcd'], [:eof]), require_all_reads: true) do |session|
      assert_equal 1, session.write('a')
      session.write('b')
      session.write('cd')
      session.expect!(:eof)
    end
  end
  def test_mismatch_reports_first_absolute_offset_without_payload
    captured = nil
    error = assert_raise(Expect4r::ReplayMismatchError) do
      Expect4r.replay(fixture([:tx, 'secret'])) do |session|
        captured = session
        session.write('sexret')
      end
    end
    assert_equal 2, error.progress[:stream_offset]
    assert_not_include error.message, 'secret'
    assert_not_include error.message, 'sexret'
    assert captured.closed?
    assert captured.reader.closed?
    assert captured.writer.closed?
  end
  def test_missing_tx_and_strict_unread_rx_are_rejected_on_close
    captured = nil
    assert_raise(Expect4r::ReplayIncompleteError) do
      Expect4r.replay(fixture([:tx, 'go'])) { |session| captured = session }
    end
    assert captured.closed?
    assert_raise(Expect4r::ReplayIncompleteError) do
      Expect4r.replay(fixture([:rx, 'ENDtail']), fragment_size: 1, require_all_reads: true) { |session| session.expect!('END') }
    end
    Expect4r.replay(fixture([:rx, 'ENDtail']), fragment_size: 1) do |session|
      session.expect!('END')
      assert session.verify_replay!
      assert_raise(Expect4r::ReplayIncompleteError) { session.verify_replay!(require_all_reads: true) }
    end
  end
  def test_redacted_spans_require_exact_length_substitutions_and_are_filtered
    source = fixture([:rx, 'Password: '], [:tx, "secret\r"], [:rx, "secret\r\nok>"], [:eof], secrets: ['secret'])
    trace = Expect4r::ReplayTrace.load(source)
    assert_equal 2, trace.redactions.size
    assert trace.redactions.frozen?
    assert_raise(Expect4r::ReplayFormatError) { Expect4r.replay(trace) }
    replacements = trace.redactions.to_h { |span| [[span[:direction], span[:stream_offset]], 'dummy!'] }
    output = StringIO.new
    Expect4r.replay(trace, substitutions: replacements, fragment_size: 1, require_all_reads: true) do |session|
      session.with_debug(output:, bytes: true) do
        session.expect!('Password: ')
        session.send_line('dummy!')
        session.expect!('ok>')
        session.expect!(:eof)
      end
    end
    assert_not_include output.string, 'dummy!'
    wrong = replacements.transform_values { 'short' }
    assert_raise(Expect4r::ReplayFormatError) { Expect4r.replay(trace, substitutions: wrong) }
    assert_raise(Expect4r::ReplayFormatError) { Expect4r.replay(trace, substitutions: replacements.merge([:tx, 99] => 'x')) }
  end
  def test_recorded_partial_write_error_is_injected_after_confirmed_prefix
    source = fixture([:tx, 'ab'], [:write_error, 'Errno::EPIPE'], [:eof])
    Expect4r.replay(source, require_all_reads: true) do |session|
      error = assert_raise(Expect4r::TransportError) { session.write('abcd') }
      assert_equal 2, error.bytes_written
      assert_equal 'Errno::EPIPE', error.cause.recorded_class
      session.expect!(:eof)
    end
  end
  def test_recorded_read_error_and_write_timeout
    Expect4r.replay(fixture([:read_error, 'Errno::ECONNRESET'], [:eof]), require_all_reads: true) do |session|
      error = assert_raise(Expect4r::TransportError) { session.expect!('never') }
      assert_equal 'Errno::ECONNRESET', error.cause.recorded_class
      session.expect!(:eof)
    end
    Expect4r.replay(fixture([:tx, 'ab'], [:write_timeout], [:eof]), require_all_reads: true) do |session|
      error = assert_raise(Expect4r::WriteTimeout) { session.write('abcd') }
      assert_equal 2, error.bytes_written
      session.expect!(:eof)
    end
  end
  def timed_fixture
    altered(fixture([:rx, 'early'], [:rx, 'late'], [:eof])) do |rows|
      late = false
      rows.drop(1).each do |row|
        late = true if row['type'] == 'io' && row['stream_offset'] == 5
        row['elapsed'] = late ? 0.1 : 0.0
      end
    end
  end
  def test_scaled_timing_reproduces_silence_and_stops_timer
    before = Thread.list.count { |thread| thread.name == 'expect4r-replay' }
    Expect4r.replay(timed_fixture, timing: :scaled, require_all_reads: true) do |session|
      session.expect!('early')
      assert session.expect('late', timeout: 0.02).timeout?
      assert_equal 'late', session.expect!('late', timeout: 1).match
      session.expect!(:eof)
    end
    assert_equal before, Thread.list.count { |thread| thread.name == 'expect4r-replay' }
    Expect4r.replay(timed_fixture, timing: :scaled, speed: 100, require_all_reads: true) do |session|
      assert_equal 'earlylate', session.capture_until('missing', timeout: 1).output
    end
  end
  def test_immediate_timing_ignores_recorded_delays_and_does_not_invent_eof
    Expect4r.replay(timed_fixture, require_all_reads: true) do |session|
      session.expect!('early')
      assert session.expect!('late', timeout: 0).matched?
      session.expect!(:eof)
    end
    Expect4r.replay(fixture([:rx, 'partial'])) do |session|
      result = session.capture_until('END', timeout: 0.02)
      assert_equal :timeout, result.status
      assert_equal 'partial', result.output
    end
  end
  def test_interact_and_aggregate_wait_use_native_selectable_endpoints
    input, feeder = IO.pipe
    feeder.write("\x14")
    output = StringIO.new
    Expect4r.replay(fixture([:rx, 'manual'])) do |session|
      assert_equal :escape, session.interact(input:, output:, raw: false).reason
      assert_equal 'manual', output.string
    end
    Expect4r.replay(fixture([:rx, 'foo'], [:eof])) do |first|
      Expect4r.replay(fixture([:rx, 'bar'], [:eof])) do |second|
        assert_same second, Expect4r.expect!('bar', from: [first, second]).session
      end
    end
  ensure
    input&.close
    feeder&.close
  end
  def test_invalid_recordings_are_rejected_before_transport_creation
    source = fixture([:rx, 'data'], [:eof])
    variants = [
      ->(rows) { rows.first['version'] = 99 },
      ->(rows) { rows.last['complete'] = false },
      ->(rows) { rows[1]['sequence'] = 8 },
      ->(rows) { rows[1]['sequence'] = 1.0 },
      ->(rows) { rows[1]['stream_offset'] = 1 },
      ->(rows) { rows.find { |r| r['type'] == 'payload' }['data'] = '#' },
      ->(rows) { rows.find { |r| r['type'] == 'payload' }['bytes'] = 100 },
      ->(rows) { rows.last['observed_bytes']['rx'] = 0 },
      ->(rows) { rows.last['observed_bytes']['rx'] = 4.0 },
      ->(rows) { rows.find { |r| r['type'] == 'payload' }['stream_offset'] = 1 },
      ->(rows) { rows.find { |r| r['type'] == 'event' }['metadata']['session_id'] = 'foreign' },
      ->(rows) { rows.last['elapsed'] = -1 },
      ->(rows) { rows[1]['type'] = 'unknown' }
    ]
    variants.each do |change|
      assert_raise(Expect4r::ReplayFormatError) { Expect4r.replay(altered(source, &change)) }
    end
    assert_raise(Expect4r::ReplayFormatError) { Expect4r.replay(StringIO.new(source.string.chomp)) }
    assert_raise(Expect4r::ReplayFormatError) { Expect4r.replay(StringIO.new('{invalid}\n')) }
  end
  def test_primary_error_survives_verification_failure_and_closes_timer
    captured = nil
    error = assert_raise(RuntimeError) do
      Expect4r.replay(fixture([:tx, 'expected']), timing: :scaled) do |session|
        captured = session
        raise 'primary application failure'
      end
    end
    assert_equal 'primary application failure', error.message
    assert captured.closed?
    assert captured.cleanup_errors.any? { |failure| failure.is_a?(Expect4r::ReplayIncompleteError) }
  end
  def test_replay_options_and_non_replay_verification
    source = fixture([:eof])
    [{ fragment_size: 0 }, { timing: :unknown }, { speed: 0 }, { require_all_reads: nil }].each do |options|
      assert_raise(ArgumentError) { Expect4r.replay(StringIO.new(source.string), **options) }
    end
    with_input { |session, peer| assert_raise(Expect4r::UnsupportedOperation) { session.verify_replay! } }
    Expect4r.replay(StringIO.new(source.string)) do |session|
      assert_nil session.pid
      assert_raise(Expect4r::UnsupportedOperation) { session.wait }
      session.expect!(:eof)
    end
  end
  def test_early_match_can_write_while_recorded_rx_tail_is_still_queued
    source = fixture([:rx, 'Password: '], [:tx, "pw\r"], [:rx, 'ok>'], [:eof])
    Expect4r.replay(source, fragment_size: 1, require_all_reads: true) do |session|
      assert_equal 'Password:', session.expect!(/Password: ?\z/).match
      session.send_line('pw')
      assert_equal ' ', session.expect!('ok>').before
      session.expect!(:eof)
    end
  end
  def test_invalid_masks_and_rx_after_eof_are_rejected
    source = fixture([:rx, 'secret'], [:eof], secrets: ['secret'])
    bad_mask = altered(source) do |rows|
      payload = rows.find { |row| row['type'] == 'payload' }
      payload['data'] = ['xxxxxx'].pack('m0')
    end
    assert_raise(Expect4r::ReplayFormatError) { Expect4r.replay(bad_mask) }
    overlapping = altered(source) do |rows|
      payload = rows.find { |row| row['type'] == 'payload' }
      payload['redactions'] << payload['redactions'].first.dup
    end
    assert_raise(Expect4r::ReplayFormatError) { Expect4r.replay(overlapping) }
    assert_raise(Expect4r::ReplayFormatError) { Expect4r.replay(fixture([:eof], [:rx, 'late'])) }
  end

end
