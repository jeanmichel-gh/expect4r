# frozen_string_literal: true
require_relative '../test_helper'

class DiagnosticEventsTest < CoreTest
  def test_rule_order_absolute_offsets_and_metadata_only
    events = []
    label = +'device'
    with_input('xxreadyTAIL', diagnostics: events.method(:<<), label:) do |session, peer|
      label.replace('changed')
      session.redact('ready')
      result = session.expect!(timeout: 1) do
        on 'absent', name: :first
        on 'ready', name: :ready
      end
      assert_equal 'TAIL', result.after
      attempts = events.select { |e| e[:event] == :rule_attempt && e[:buffered_bytes].positive? }
      assert_equal [:first, :ready], attempts.map { |e| e[:rule_name] }
      hit = events.find { |e| e[:event] == :match }
      assert_equal [2, 7], hit.values_at(:from_offset, :to_offset)
      assert_equal 7, session.buffer_offset
      session.expect!('TAIL', timeout: 0)
      assert_equal 11, session.buffer_offset
      assert events.all?(&:frozen?)
      assert events.all? { |e| e[:label] == 'device' && e[:label].frozen? }
      assert_equal (1..events.size).to_a, events.map { |e| e[:sequence] }
      assert_equal events.map { |e| e[:monotonic] }.sort, events.map { |e| e[:monotonic] }
      assert events.none? { |e| e.key?(:pattern) || e.key?(:buffer) || e.key?(:payload) }
      assert_not_include events.inspect, 'xxreadyTAIL'
    end
  end

  def test_non_consuming_match_and_clear_offsets
    events = []
    with_input('abc', diagnostics: events.method(:<<)) do |session, peer|
      session.expect!('abc', consume: false)
      assert_equal 0, session.buffer_offset
      assert events.none? { |e| e[:event] == :consume }
      assert_equal 'abc', session.clear_buffer
      assert_equal 3, session.buffer_offset
      peer.write('def')
      session.expect!('def')
      assert_equal [3, 6], events.select { |e| e[:event] == :match }.last.values_at(:from_offset, :to_offset)
    end
  end

  def test_continuation_and_deadline_causes
    events = []
    with_input('one two', diagnostics: events.method(:<<)) do |session, peer|
      session.expect!(timeout: 1, total_timeout: 2) do
        on('one') { exp_continue }
        on('two')
      end
      continuation = events.find { |e| e[:event] == :continuation }
      assert_equal true, continuation[:reset_timeout]
      deadlines = events.select { |e| e[:event] == :deadlines }
      assert_equal [:initial, :continuation], deadlines.map { |e| e[:cause] }
      assert_equal deadlines.first[:total_deadline], deadlines.last[:total_deadline]
      assert_operator deadlines.last[:relative_deadline], :>=, deadlines.first[:relative_deadline]
    end
    [[:timeout, { timeout: 0 }], [:idle_timeout, { timeout: 1, idle_timeout: 0 }],
     [:total_timeout, { timeout: 1, total_timeout: 0 }]].each do |reason, options|
      events.clear
      with_input(diagnostics: events.method(:<<)) do |session, peer|
        assert session.expect('missing', **options).timeout?
        assert_equal reason, events.find { |e| e[:event] == :timeout }[:reason]
      end
    end
  end

  def test_aggregate_wait_correlates_sources
    events = []
    with_input(diagnostics: events.method(:<<)) do |first, first_peer|
      with_input('ready', diagnostics: events.method(:<<)) do |second, second_peer|
        result = Expect4r.expect!('ready', from: [first, second], timeout: 1)
        assert_same second, result.session
        starts = events.select { |e| e[:event] == :wait_start }
        assert_equal 1, starts.map { |e| e[:wait_id] }.uniq.size
        assert_equal 2, starts.map { |e| e[:session_id] }.uniq.size
        assert events.select { |e| e[:event] == :wait_result }.all? { |e| e[:selected_session_id] == second.session_id }
        assert_nil first.diagnostic_wait_id
        assert_nil second.diagnostic_wait_id
      end
    end
  end

  def test_overflow_and_eof_metadata
    events = []
    with_input('abcdef', buffer_limit: 3, diagnostics: events.method(:<<)) do |session, peer|
      error = assert_raise(Expect4r::BufferOverflow) { session.expect('never') }
      assert_equal 'def', error.rejected
      overflow = events.find { |e| e[:event] == :overflow }
      assert_equal [3, 3], overflow.values_at(:buffered_bytes, :rejected_bytes)
      session.clear_buffer
      assert_equal 6, session.buffer_offset
    end
    events.clear
    with_input('partial', eof: true, diagnostics: events.method(:<<)) do |session, peer|
      assert session.expect(:eof).eof?
      assert_equal 7, events.find { |e| e[:event] == :eof }[:stream_offset]
    end
  end

  def test_encoding_error_is_not_a_failed_match
    events = []
    with_input("\xff".b, diagnostics: events.method(:<<)) do |session, peer|
      assert_raise(Expect4r::EncodingError) { session.expect(/é/) }
      assert_equal 'Expect4r::EncodingError', events.find { |e| e[:event] == :rule_error }[:error_class]
      assert events.any? { |e| e[:event] == :wait_error }
    end
  end

  def test_sink_failure_releases_ownership_and_preserves_error
    calls = 0
    sink = ->(event) { calls += 1; raise IOError, 'sink failed' }
    with_input('ready', diagnostics: sink) do |session, peer|
      error = assert_raise(IOError) { session.expect('ready') }
      assert_equal 'sink failed', error.message
      assert_equal 1, calls
      assert_nil session.diagnostic_wait_id
      assert session.expect!('ready').matched?
    end
  end

  def test_interaction_handoff_and_subsequent_automation
    events = []
    input, feeder = IO.pipe
    feeder.write("hello\x14")
    with_input(diagnostics: events.method(:<<)) do |session, peer|
      result = session.interact(input:, output: StringIO.new, raw: false)
      assert_equal :escape, result.reason
      assert_equal 'hello', peer.read(5)
      assert_equal [:interaction_start, :interaction_end], events.select { |e| e[:event].to_s.start_with?('interaction_') }.map { |e| e[:event] }
      assert_equal :escape, events.find { |e| e[:event] == :interaction_end }[:reason]
      assert_equal 5, events.find { |e| e[:event] == :write_progress }[:confirmed_bytes]
      peer.write('ready')
      assert session.expect!('ready').matched?
    end
  ensure
    input&.close
    feeder&.close
  end

  def test_disabled_diagnostics_does_not_inspect_payload_or_patterns
    pattern = +'ready'
    def pattern.inspect = raise('must not format pattern')
    with_input('ready') { |session, peer| assert session.expect!(pattern).matched? }
    assert_raise(TypeError) { Expect4r.spawn('unused', diagnostics: Object.new) }
    assert_raise(TypeError) { Expect4r.spawn('unused', label: 123) }
  end
  def test_registration_error_and_read_sink_failure_preserve_input
    events = []
    with_input('ready', diagnostics: events.method(:<<)) do |session, peer|
      assert_raise(Expect4r::EmptyMatchError) { session.expect('') }
      assert_equal 'Expect4r::EmptyMatchError', events.last[:error_class]
      assert_equal :registration_error, events.last[:event]
    end
    sink = ->(event) { raise 'receive sink failed' if event[:event] == :receive }
    with_input('ready', diagnostics: sink) do |session, peer|
      assert_raise(RuntimeError) { session.expect('ready') }
      assert_equal 'ready', session.buffer
      assert session.expect!('ready').matched?
    end
  end

end
