# frozen_string_literal: true
require_relative '../test_helper'
class CaptureTest < CoreTest
  def partial_sink(fail_after: nil)
    Class.new do
      attr_reader :data
      def initialize(fail_after)
        @data, @calls, @fail_after = ''.b, 0, fail_after
      end
      def write(bytes)
        @calls += 1
        raise IOError, 'sink stopped' if @fail_after && @calls > @fail_after
        part = bytes.byteslice(0, 2)
        @data << part
        part.bytesize
      end
    end.new(fail_after)
  end
  def test_streams_binary_data_and_retains_only_bounded_tail
    sink = partial_sink
    bytes = "hello\0\xff".b * 10
    terminator = "\0END".b
    with_input(bytes + terminator + 'tail', buffer_limit: 8) do |session, peer|
      result = session.capture_until!(terminator, sink:, retain: 5)
      assert_equal bytes, sink.data
      assert_equal bytes.bytesize, result.output_bytes
      assert_equal bytes.bytesize, result.sink_bytes
      assert_equal bytes.byteslice(-5, 5), result.output
      assert result.output.frozen?
      assert result.truncated
      assert result.success?
      assert_equal 'tail', session.buffer + session.staged_buffer
      assert_not_include result.inspect, 'hello'
    end
  end
  def test_literal_terminator_crosses_physical_read_boundaries
    with_input('abcENDtail', buffer_limit: 4) do |session, peer|
      reader = session.reader
      original = reader.method(:read_nonblock)
      reader.define_singleton_method(:read_nonblock) do |size, exception:|
        original.call([2, size].min, exception:)
      end
      result = session.capture_until!('END')
      assert_equal 'abc', result.output
      assert_equal 'END', result.event.match
    end
  end
  def test_regexp_requires_declared_window_and_preserves_utf8_boundaries
    content = 'é' * 50
    with_input(content + '終', buffer_limit: 9) do |session, peer|
      result = session.capture_until!(/終/, match_window: 3, retain: nil)
      assert_equal content.b, result.output
      assert_equal content.bytesize, result.output_bytes
      assert_equal false, result.truncated
    end
  end
  def test_count_only_and_total_limit_are_independent_of_retention
    capture = Expect4r::Capture.new(retain: 0, limit: 4)
    assert_equal 2, capture.append('ab')
    error = assert_raise(Expect4r::CaptureLimitError) { capture.append('cde') }
    assert_equal 2, capture.bytes
    assert_equal '', capture.output
    assert_equal 'cde', error.rejected
    assert_equal 0, error.bytes_written
    assert_equal 2, error.progress[:captured_bytes]
    assert capture.failed?
    assert_raise(Expect4r::CaptureError) { capture.append('x') }
  end
  def test_direct_capture_reports_confirmed_partial_sink_progress
    sink = partial_sink(fail_after: 1)
    capture = Expect4r::Capture.new(sink:, retain: 10)
    error = assert_raise(Expect4r::CaptureSinkError) { capture.append('abcdef') }
    assert_equal [2, 2], [capture.bytes, capture.sink_bytes]
    assert_equal 'ab', capture.output
    assert_equal 'cdef', error.rejected
    assert_equal 2, error.bytes_written
    assert_kind_of IOError, error.cause
    assert_kind_of Expect4r::CaptureError, error
    assert_equal 'ab', sink.data
  end
  def test_failed_full_buffer_capture_consumes_only_confirmed_bytes
    failed = partial_sink(fail_after: 1)
    with_input('abcdefEND', buffer_limit: 6) do |session, peer|
      error = assert_raise(Expect4r::CaptureSinkError) { session.capture_until!('END', sink: failed) }
      assert_equal 2, error.bytes_written
      assert_equal 'ab', failed.data
      assert_equal 'cdefEND', session.buffer + session.staged_buffer
      recovered = StringIO.new
      result = session.capture_until!('END', sink: recovered)
      assert_equal 'cdef', recovered.string
      assert_equal 4, result.output_bytes
    end
  end
  def test_failed_final_match_capture_preserves_unconfirmed_bytes_and_marker
    failed = partial_sink(fail_after: 1)
    with_input('abcdEND', buffer_limit: 16) do |session, peer|
      assert_raise(Expect4r::CaptureSinkError) { session.capture_until!('END', sink: failed) }
      assert_equal 'cdEND', session.buffer
      assert_equal 'cd', session.capture_until!('END').output
    end
  end
  def test_failed_eof_capture_preserves_unconfirmed_bytes
    failed = partial_sink(fail_after: 1)
    with_input('abcd', eof: true, buffer_limit: 16) do |session, peer|
      assert_raise(Expect4r::CaptureSinkError) { session.capture_until('END', sink: failed) }
      assert_equal 'cd', session.buffer
      result = session.capture_until('END')
      assert_equal :eof, result.status
      assert_equal 'cd', result.output
    end
  end
  def test_timeout_captures_partial_output_and_bang_attaches_capture_result
    with_input('partial', buffer_limit: 16) do |session, peer|
      error = assert_raise(Expect4r::ExpectTimeout) { session.capture_until!('END', timeout: 0.02) }
      assert_kind_of Expect4r::CaptureResult, error.result
      assert_equal 'partial', error.result.output
      assert_equal :timeout, error.result.event.reason
      assert_empty session.buffer
    end
    with_input('partial', eof: true, buffer_limit: 16) do |session, peer|
      error = assert_raise(Expect4r::UnexpectedEOF) { session.capture_until!('END') }
      assert_equal 'partial', error.result.output
    end
  end
  def test_limit_rejects_whole_append_without_consuming_input
    with_input('abcdEND', buffer_limit: 16) do |session, peer|
      error = assert_raise(Expect4r::CaptureLimitError) { session.capture_until!('END', limit: 3) }
      assert_equal 0, error.progress[:captured_bytes]
      assert_equal 'abcdEND', session.buffer
      assert_equal 'abcd', session.capture_until!('END').output
    end
  end
  def test_sink_invalid_progress_is_rejected
    [0, -1, nil, 100].each do |count|
      sink = Object.new
      sink.define_singleton_method(:write) { |bytes| count }
      capture = Expect4r::Capture.new(sink:)
      error = assert_raise(Expect4r::CaptureSinkError) { capture.append('abc') }
      assert_equal 0, error.bytes_written
      assert_equal 0, capture.bytes
    end
  end
  def test_capture_settings_fail_before_input_is_consumed
    with_input('abcEND', buffer_limit: 8) do |session, peer|
      assert_raise(ArgumentError) { session.capture_until(/END/) }
      assert_raise(ArgumentError) { session.capture_until('END', match_window: false) }
      assert_raise(ArgumentError) { session.capture_until('END', match_window: 2) }
      assert_raise(ArgumentError) { session.capture_until('END', match_window: 9) }
      assert_raise(ArgumentError) { session.capture_until('END', retain: -1) }
      assert_raise(TypeError) { session.capture_until('END', sink: Object.new) }
      assert_raise(Expect4r::EmptyMatchError) { session.capture_until('') }
      assert_equal 'abc', session.capture_until!('END').output
    end
  end
  def test_sustained_real_pty_output_keeps_matching_and_retention_bounded
    sink = Class.new do
      attr_reader :bytes
      def initialize = @bytes = 0
      def write(data)
        @bytes += data.bytesize
        data.bytesize
      end
    end.new
    child('STDOUT.write("x" * 300_000 + "END")', buffer_limit: 4096) do |session|
      result = session.capture_until!('END', sink:, retain: 32, total_timeout: 10)
      assert_equal 300_000, sink.bytes
      assert_equal 300_000, result.output_bytes
      assert_equal 32, result.output.bytesize
      assert result.truncated
      assert_operator result.event.before.bytesize, :<=, 4096
    end
  end
  def test_slow_sink_does_not_reset_total_deadline
    sink = Object.new
    def sink.write(bytes)
      sleep 0.02
      bytes.bytesize
    end
    with_input('abcdefEND', buffer_limit: 6) do |session, peer|
      result = session.capture_until('END', sink:, total_timeout: 0.01)
      assert_equal :timeout, result.status
      assert_equal :total_timeout, result.event.reason
      assert_equal 'END', session.staged_buffer
      assert_equal 'abcdef', result.output
    end
  end
  def test_literal_streaming_matches_whole_input_reference_across_window_sizes
    rng = Random.new(12345)
    30.times do
      content = Array.new(50) { rng.rand(0..255) }.pack('C*')
      marker = "abcx".b
      expected = (content + marker).split(marker, 2).first
      with_input(content + marker + 'tail', buffer_limit: rng.rand(4..12)) do |session, peer|
        result = session.capture_until!(marker, retain: nil)
        assert_equal expected, result.output
        assert_equal 'tail', session.buffer + session.staged_buffer
      end
    end
  end
  def test_regexp_window_requires_room_for_character_safe_progress
    with_input('éé終', buffer_limit: 3) do |session, peer|
      assert_raise(Expect4r::BufferProgressError) { session.capture_until(/終/, match_window: 3) }
      assert_equal 'éé終'.b, session.buffer + session.staged_buffer
    end
  end
  def test_capture_leaves_following_dialogue_for_next_capture
    with_input('abcENDdefEND', buffer_limit: 4) do |session, peer|
      assert_equal 'abc', session.capture_until!('END').output
      assert_equal 'def', session.capture_until!('END').output
    end
  end

end
