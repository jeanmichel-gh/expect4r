# frozen_string_literal: true
require_relative '../test_helper'
class ReviewRegressionTest < CoreTest
  def test_overlapping_secrets_cover_every_occurrence_across_fragmentation
    [['abcdef', ['abc', 'bcdef']], ['ababa', ['aba']], ['aaax', ['aa']]].each do |value, secrets|
      expected = value.dup
      secrets.each do |secret|
        at = 0
        while (hit = value.index(secret, at))
          expected[hit, secret.bytesize] = "\0" * secret.bytesize
          at = hit + 1
        end
      end
      (1..value.bytesize).each do |width|
        redactor = Expect4r::Redactor.new
        secrets.each { |secret| redactor.add(secret) }
        output = ''.b
        value.bytes.each_slice(width) { |part| output << redactor.feed(part.pack('C*')) }
        output << redactor.feed(''.b, final: true)
        # Markers may split across emissions; only non-secret bytes can remain.
        assert_equal expected.delete("\0"), output.gsub('[REDACTED]', '')
      end
    end
  end
  def test_transcript_failure_does_not_hide_overflow_rejected_bytes
    sink = Object.new
    def sink.write(bytes) = raise(IOError, 'transcript failed')
    with_input('abcdef', buffer_limit: 3, transcript: sink) do |session, peer|
      error = assert_raise(Expect4r::BufferOverflow) { session.expect('never') }
      assert_equal 'abc', error.buffer
      assert_equal 'def', error.rejected
      assert session.cleanup_errors.any? { |failure| failure.is_a?(IOError) }
    end
  end
  def test_failed_receive_diagnostics_do_not_reset_streaming_redaction
    transcript = StringIO.new
    sink = ->(event) { raise 'diagnostics failed' if event[:event] == :receive }
    with_input('pass', transcript:, diagnostics: sink) do |session, peer|
      session.redact('password')
      assert_raise(RuntimeError) { session.expect('pass') }
      assert_equal 'pass', session.clear_buffer
      peer.write('word!')
      session.expect!('word!')
      assert_equal '[REDACTED]!', transcript.string
    end
  end
  def test_backpressure_diagnostic_failure_retains_fresh_read_bytes
    armed = false
    sink = lambda do |event|
      raise 'deadline diagnostics failed' if armed && event[:event] == :deadlines && event[:cause] == :receive
    end
    with_input('go', diagnostics: sink) do |session, peer|
      original = session.writer.method(:write_nonblock)
      first = true
      session.writer.define_singleton_method(:write_nonblock) do |bytes, exception:|
        if first
          first = false
          :wait_writable
        else
          original.call(bytes, exception:)
        end
      end
      assert_raise(RuntimeError) do
        session.expect!(idle_timeout: 1) do
          on 'go' do
            armed = true
            peer.write('payload')
            write('x')
          end
        end
      end
      assert_equal 'payload', session.buffer
      assert session.expect!('payload').matched?
    end
  end
  def test_remote_eof_returns_held_escape_prefix_to_script
    recording = StringIO.new
    recorder = Expect4r::Diagnostics::Recording.new(recording, session_id: 'review', label: nil)
    recorder.io(:rx, 'bye')
    recorder.event(session_id: 'review', event: :eof)
    recorder.finish(complete: true)
    input, sender = IO.pipe
    sender.write('E')
    Expect4r.replay(StringIO.new(recording.string), require_all_reads: true) do |session|
      result = session.interact(input:, output: StringIO.new, escape: 'END', timeout: 1)
      assert_equal :eof, result.reason
      assert_equal 'E', result.pending_input
      assert result.pending_input.frozen?
    end
  ensure
    input&.close
    sender&.close
  end
  def test_redaction_uses_byte_offsets_for_non_ascii_input
    redactor = Expect4r::Redactor.new
    redactor.add('secret')
    assert_equal 'é[REDACTED]!'.b, redactor.feed('ésecret!', final: true)
  end
  def test_remote_eof_leaves_new_keyboard_input_unread
    recording = StringIO.new
    recorder = Expect4r::Diagnostics::Recording.new(recording, session_id: 'review', label: nil)
    recorder.event(session_id: 'review', event: :eof)
    recorder.finish(complete: true)
    input, sender = IO.pipe
    sender.write('command')
    Expect4r.replay(StringIO.new(recording.string), require_all_reads: true) do |session|
      result = session.interact(input:, output: StringIO.new, timeout: 1)
      assert_equal :eof, result.reason
      assert_equal 'command', input.read(7)
    end
  ensure
    input&.close
    sender&.close
  end

end
