# frozen_string_literal: true
require_relative '../test_helper'
class RegressionTest < CoreTest
  def test_logging_failure_does_not_lose_received_bytes
    sink = Object.new
    def sink.write(_bytes) = raise(RuntimeError, 'sink unavailable')
    with_input('ready>', transcript: sink) do |session|
      assert_raise(RuntimeError) { session.expect('ready>') }
      assert_equal 'ready>', session.buffer
      assert_equal 'ready>', session.expect!('ready>').match
    end
  end
  def test_read_only_pipe_is_validated_before_taking_ownership
    reader, writer = IO.pipe
    assert_raise(IOError) { Expect4r.open(reader, own: true) }
    assert !reader.closed?
    assert !writer.closed?
    Expect4r.open(reader, writer:, own: false) do |session|
      writer.write('ready')
      assert session.expect!('ready').matched?
    end
  ensure
    reader&.close
    writer&.close
  end
  def test_known_eof_and_buffered_match_win_over_zero_budget
    with_input('ready tail', eof: true) do |session|
      assert session.expect!('ready', timeout: 0).matched?
      assert_equal ' tail', session.expect!(:eof, timeout: 1).before
      assert session.expect!(:eof, timeout: 0).eof?
    end
  end
  def test_exact_bytes_and_line_endings
    with_input do |session, peer|
      assert_equal 6, session.send_line('  x ', ending: "\r\n")
      assert_equal "  x \r\n", peer.read(6)
      assert_equal 2, session.write("\x00\xff".b)
      assert_equal "\x00\xff".b, peer.read(2)
      assert_raise(ArgumentError) { session.write('x', sensitive: :yes) }
      assert_equal :wait_readable, peer.read_nonblock(1, exception: false)
    end
  end
  def test_incomplete_and_impossible_utf8_are_distinguished
    ["\xe0\x80".b, "\xed\xa0".b, "\xf0\x80".b, "\xf4\x90".b].each do |bytes|
      with_input(bytes) do |session|
        assert_raise(Expect4r::EncodingError) { session.expect(/café/u, timeout: 0.1) }
      end
    end
    with_input("\xc3".b, eof: true) do |session|
      assert_raise(Expect4r::EncodingError) { session.expect(/café/u) }
    end
  end
  def test_ensure_runs_on_continuation_and_total_timeout_cannot_continue
    ran = false
    with_input('one two') do |session|
      result = session.expect do |patterns|
        patterns.on('one') do
          begin
            exp_continue
          ensure
            ran = true
          end
        end
        patterns.on('two')
      end
      assert result.matched?
      assert ran
      assert_raise(Expect4r::InvalidContinuation) do
        session.expect(total_timeout: 0) { timeout { exp_continue } }
      end
    end
  end
  def test_shell_mode_is_explicit
    Expect4r.spawn('printf ready', shell: true) do |session|
      assert session.expect!('ready', timeout: 1).matched?
      assert session.wait(timeout: 1).success?
    end
    assert_raise(Expect4r::SpawnError) { Expect4r.spawn('printf ready') }
  end
  def test_cleanup_error_is_not_suppressed_by_an_unrelated_rescue
    sink = Object.new
    def sink.write(_bytes) = raise(RuntimeError, 'cleanup sink failure')
    begin
      raise 'unrelated caller error'
    rescue RuntimeError
      assert_raise(RuntimeError) do
        child('print "sec"; sleep 10', transcript: sink) do |session|
          session.redact('secret')
          session.expect!('sec')
        end
      end
    end
  end
  def test_session_reservation_covers_a_whole_conversation
    with_input('ready') do |session|
      gate, release = Queue.new, Queue.new
      thread = Thread.new { session.with_lease { gate << true; release.pop } }
      gate.pop
      assert_raise(Expect4r::BusySessionError) { session.expect('ready') }
      release << true
      thread.join
      assert session.expect!('ready').matched?
    ensure
      release << true if release
      thread&.join
    end
  end
end
