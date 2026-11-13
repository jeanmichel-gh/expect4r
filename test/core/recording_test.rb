# frozen_string_literal: true
require_relative '../test_helper'
require 'json'
class RecordingTest < CoreTest
  def records(sink) = sink.string.lines.map { |line| JSON.parse(line) }
  def payload(sink, direction)
    records(sink).select { |r| r['type'] == 'payload' && r['direction'] == direction }.map { |r| r.fetch('data').unpack1('m0') }.join.b
  end
  def test_bidirectional_binary_recording_and_complete_trailer
    sink = StringIO.new
    with_input("hello\x00\xff".b, eof: true, recording: sink, label: 'lab') do |session, peer|
      session.write("world\x00")
      assert_equal "world\x00", peer.read(6)
      assert session.expect(:eof).eof?
    end
    entries = records(sink)
    assert_equal ['expect4r-dialogue', 1, 'lab'], entries.first.values_at('format', 'version', 'label')
    assert_equal "hello\x00\xff".b, payload(sink, 'rx')
    assert_equal "world\x00", payload(sink, 'tx')
    assert_equal true, entries.last['complete']
    assert_equal [0, 7], entries.find { |r| r['type'] == 'io' && r['direction'] == 'rx' }.values_at('stream_offset', 'bytes')
    assert_equal (1...entries.size).to_a, entries.drop(1).map { |r| r['sequence'] }
    assert_equal entries.drop(1).map { |r| r['elapsed'] }.sort, entries.drop(1).map { |r| r['elapsed'] }
    assert_not_include sink.string, 'ROUTER_PASSWORD'
  end
  def test_fragmented_secrets_keep_lengths_offsets_and_redaction_ranges
    sink = StringIO.new
    with_input('pass', recording: sink) do |session, peer|
      session.redact('password')
      session.expect! do
        on('pass') { peer.write('word>'); exp_continue }
        on('>')
      end
      session.write('pass')
      session.write('word!')
    end
    assert_equal "\0" * 8 + '>', payload(sink, 'rx')
    assert_equal "\0" * 8 + '!', payload(sink, 'tx')
    assert_not_include sink.string, 'password'
    [:rx, :tx].each do |direction|
      fragments = records(sink).select { |r| r['type'] == 'payload' && r['direction'] == direction.to_s }
      assert_equal 9, fragments.sum { |r| r['bytes'] }
      assert_equal 8, fragments.flat_map { |r| r['redactions'] }.sum { |r| r['bytes'] }
      assert_equal 0, fragments.first['stream_offset']
    end
  end
  def test_overlapping_secrets_and_partial_final_prefix
    sink = StringIO.new
    with_input('aaa', recording: sink) do |session, peer|
      session.redact('aa', 'password')
      session.expect!('aaa')
      assert_equal "\0\0", payload(sink, 'rx')
      peer.write('xpass')
      session.expect!('xpass')
    end
    assert_equal "\0\0\0x\0\0\0\0", payload(sink, 'rx')
    assert records(sink).any? { |r| r['type'] == 'payload' && r['redactions'].any? }
  end
  def test_confirmed_partial_writes_only_are_recorded
    sink = StringIO.new
    with_input(recording: sink) do |session, peer|
      writer = session.writer
      original = writer.method(:write_nonblock)
      calls = 0
      writer.define_singleton_method(:write_nonblock) do |data, exception:|
        calls += 1
        raise Errno::EPIPE if calls > 1
        original.call(data.byteslice(0, 2), exception:)
      end
      error = assert_raise(Expect4r::TransportError) { session.write('abcdef') }
      assert_equal 2, error.bytes_written
      assert_equal 'ab', peer.read(2)
      assert_equal 'ab', payload(sink, 'tx')
      assert_equal 2, records(sink).select { |r| r['type'] == 'io' && r['direction'] == 'tx' }.sum { |r| r['bytes'] }
    end
  end
  def test_history_is_immutable_and_bounded_by_both_limits
    with_input('abc', history: { max_events: 4, max_bytes: 2000 }) do |session, peer|
      session.expect!('a')
      snapshot = session.diagnostic_history
      session.expect!('b')
      assert snapshot.frozen?
      assert snapshot.all?(&:frozen?)
      assert_operator session.diagnostic_history.size, :<=, 4
      assert_operator session.diagnostic_history_bytes, :<=, 2000
      assert_operator session.diagnostic_history_dropped, :>, 0
      assert_not_equal snapshot, session.diagnostic_history
      assert snapshot.none? { |e| e.key?(:payload) || e.key?(:pattern) }
    end
    with_input('x', history: { max_events: 10, max_bytes: 1 }) do |session, peer|
      session.expect!('x')
      assert_empty session.diagnostic_history
      assert_equal 0, session.diagnostic_history_bytes
      assert_operator session.diagnostic_history_dropped, :>, 0
    end
  end
  def test_failed_recording_never_gets_a_complete_trailer_and_preserves_read_bytes
    sink = StringIO.new
    count = 0
    original = sink.method(:write)
    sink.define_singleton_method(:write) do |bytes|
      count += 1
      raise IOError, 'recording failed' if bytes.include?('"type":"payload"')
      original.call(bytes)
    end
    with_input('ready', recording: sink) do |session, peer|
      assert_raise(Expect4r::TransportError) { session.expect!('ready') }
      assert session.recording_failed?
      assert_equal 'ready', session.buffer
      assert session.expect!('ready').matched?
    end
    assert records(sink).none? { |r| r['type'] == 'end' && r['complete'] }
  end
  def test_primary_application_error_survives_finalization_sink_failure
    sink = Object.new
    def sink.write(bytes) = raise(IOError, 'broken recording')
    captured = nil
    error = assert_raise(RuntimeError) do
      with_input(recording: sink) do |session, peer|
        captured = session
        raise 'application failed'
      end
    end
    assert_equal 'application failed', error.message
    assert captured.closed?
    assert captured.recording_failed?
    assert captured.cleanup_errors.any?
  end
  def test_settings_validate_before_spawn
    assert_raise(TypeError) { Expect4r.spawn('unused', recording: Object.new) }
    [{}, { max_events: 0, max_bytes: 1 }, { max_events: 1 }].each do |history|
      assert_raise(ArgumentError) { Expect4r.spawn('unused', history:) }
    end
  end
  def test_fragmentation_matches_whole_stream_redaction_oracle
    rng = Random.new(12345)
    50.times do
      value = Array.new(60) { 'abc'[rng.rand(3)] }.join
      secrets = ['ab', 'bca', 'aaa']
      sink = StringIO.new
      recorder = Expect4r::Diagnostics::Recording.new(sink, session_id: 'test', label: nil)
      secrets.each { |secret| recorder.redact(secret) }
      at = 0
      while at < value.bytesize
        width = rng.rand(1..7)
        recorder.io(:rx, value.byteslice(at, width))
        at += width
      end
      recorder.finish(complete: true)
      expected = value.dup
      secrets.each do |secret|
        pos = 0
        while (hit = value.index(secret, pos))
          expected[hit, secret.size] = "\0" * secret.size
          pos = hit + 1
        end
        1.upto(secret.size - 1) do |size|
          expected[-size, size] = "\0" * size if secret.start_with?(value[-size, size])
        end
      end
      assert_equal expected, payload(sink, 'rx')
    end
  end
  def test_outgoing_logger_filters_secrets_across_write_calls
    log = StringIO.new
    with_input(logger: Logger.new(log)) do |session, peer|
      session.redact('password')
      session.trace_bytes = true
      session.write('pass')
      session.write('word!')
    end
    assert_not_include log.string, 'password'
    assert_not_include log.string, 'word!'
    assert_include log.string, '[REDACTED]!'
  end

  def test_overflow_records_rejected_bytes_and_partial_sink_writes
    sink = StringIO.new
    original = sink.method(:write)
    sink.define_singleton_method(:write) { |bytes| original.call(bytes.byteslice(0, 7)) }
    with_input('abcdef', recording: sink, buffer_limit: 3) do |session, peer|
      assert_raise(Expect4r::BufferOverflow) { session.expect('missing') }
    end
    assert_equal 'abcdef', payload(sink, 'rx')
    assert_equal true, records(sink).last['complete']
  end

end
