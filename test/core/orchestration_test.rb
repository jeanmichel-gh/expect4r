# frozen_string_literal: true
require_relative '../test_helper'
class OrchestrationTest < CoreTest
  def test_multiple_sources_priority_and_timeout_snapshots
    with_input('ready A') do |a|
      with_input('ready B') do |b|
        result = Expect4r.expect(from: [a, b], timeout: 1) do |patterns|
          patterns.on('ready B', from: b, name: :b)
          patterns.on('ready A', from: a, name: :a)
        end
        assert_equal :b, result.name
        assert_same b, result.session
        timeout = Expect4r.expect('never', from: [a, b], timeout: 0.01)
        assert_nil timeout.session
        assert_equal 'ready A', timeout.pending[a]
        assert_equal '', timeout.pending[b]
      end
    end
  end
  def test_aggregate_timeout_continuation_and_ownership_rollback
    with_input do |a, peer|
      with_input do |b|
        result = Expect4r.expect(from: [a, b], timeout: 0.01) do |patterns|
          patterns.on('ready', from: a)
          patterns.timeout { peer.write('ready'); exp_continue }
        end
        assert_same a, result.session
        assert_raise(Expect4r::ReentrancyError) do
          a.expect(timeout: 0.01) { timeout { Expect4r.expect('x', from: [b, a], timeout: 0) } }
        end
        assert b.expect('x', timeout: 0).timeout?
      end
    end
  end
  def test_interaction_handles_split_escape_and_retains_typed_suffix
    with_input('banner') do |session, peer|
      input, sender = IO.pipe
      output = StringIO.new
      producer = Thread.new { sender.write('helloEN'); sleep 0.02; sender.write('Dremaining') }
      result = session.interact(input:, output:, escape: 'END', timeout: 1)
      producer.join
      assert_equal :escape, result.reason
      assert_equal 'remaining', result.pending_input
      assert_equal 'banner', output.string
      assert_equal 'hello', peer.read(5)
      assert session.expect('never', timeout: 0).timeout?
    ensure
      input&.close
      sender&.close
    end
  end
  def test_interaction_input_eof_and_timeout_flush_pending_prefix
    with_input do |session, peer|
      input, sender = IO.pipe
      sender.write('abcE')
      sender.close
      result = session.interact(input:, output: StringIO.new, escape: 'END', timeout: 1)
      assert_equal :input_eof, result.reason
      assert_equal 'abcE', peer.read(4)
      input.close
      input, sender = IO.pipe
      sender.write('E')
      result = session.interact(input:, output: StringIO.new, escape: 'END', timeout: 0.02)
      assert_equal :timeout, result.reason
      assert_equal 'E', peer.read(1)
    ensure
      input&.close unless input&.closed?
      sender&.close unless sender&.closed?
    end
  end
  def test_interaction_restores_real_terminal_mode_after_output_failure
    master, slave = PTY.open
    # macOS sets its transient PENDIN flag on the first raw/canonical switch,
    # even with plain Ruby and no expect4r. Calibrate that kernel state first,
    # then compare every termios setting exactly across the failing interaction.
    mode = slave.console_mode
    slave.raw!
    slave.console_mode = mode
    original = IO.popen(['stty', '-g'], 'r', in: slave, &:read)
    sink = Object.new
    def sink.write(_bytes) = raise(IOError, 'output failed')
    with_input('banner') do |session|
      assert_raise(IOError) { session.interact(input: slave, output: sink, timeout: 0.1) }
      assert_equal original, IO.popen(['stty', '-g'], 'r', in: slave, &:read)
      assert session.expect('banner', timeout: 0).matched?
    end
  ensure
    master&.close
    slave&.close
  end
end
