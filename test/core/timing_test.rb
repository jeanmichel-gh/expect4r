# frozen_string_literal: true
require_relative '../test_helper'
class TimingTest < CoreTest
  def test_trickle_does_not_extend_timeout
    with_input do |session, peer|
      producer = Thread.new { 20.times { peer.write('x'); sleep 0.01 } }
      started = Expect4r.monotonic
      result = session.expect('never', timeout: 0.07)
      elapsed = Expect4r.monotonic - started
      assert_equal :timeout, result.reason
      assert_operator elapsed, :<, 0.18
      assert_operator elapsed, :>=, 0.05
    ensure
      producer&.kill
      producer&.join
    end
  end
  def test_idle_and_total_budget_reasons
    with_input do |session|
      assert_equal :idle_timeout, session.expect('x', timeout: 1, idle_timeout: 0.02).reason
      assert_equal :total_timeout, session.expect('x', timeout: 1, total_timeout: 0.02).reason
    end
  end
  def test_continuation_timer_reset
    [true, false].each do |reset|
      with_input do |session, peer|
        producer = Thread.new { sleep 0.04; peer.write('one'); sleep 0.04; peer.write('two') }
        result = session.expect(timeout: 0.065) do |patterns|
          patterns.on('one') { exp_continue(reset_timeout: reset) }
          patterns.on('two')
        end
        assert_equal reset ? :matched : :timeout, result.status
      ensure
        producer&.kill
        producer&.join
      end
    end
  end
  def test_total_budget_caps_reset_continuations
    with_input do |session, peer|
      producer = Thread.new { 20.times { peer.write('tick'); sleep 0.01 } }
      result = session.expect(timeout: 1, total_timeout: 0.06) do
        on('tick') { exp_continue }
      end
      assert_equal :total_timeout, result.reason
    ensure
      producer&.kill
      producer&.join
    end
  end
  def test_zero_timeout_polls_once_and_relative_timeout_handler_can_reset
    with_input('ready') { |session| assert session.expect('ready', timeout: 0).matched? }
    with_input do |session, peer|
      calls = 0
      result = session.expect(timeout: 0.01) do |patterns|
        patterns.on('ready')
        patterns.timeout do
          calls += 1
          peer.write('ready')
          exp_continue
        end
      end
      assert result.matched?
      assert_equal 1, calls
      assert_raise(Expect4r::InvalidContinuation) { session.expect(timeout: 0) { timeout { exp_continue } } }
    end
  end
  def test_invalid_durations
    [-1, Float::INFINITY, Float::NAN, '1', true, Complex(1, 1)].each do |value|
      assert_raise(ArgumentError) { Expect4r.duration(value) }
    end
  end
  def test_registration_time_is_part_of_total_budget
    with_input do |session, peer|
      result = session.expect(total_timeout: 0.01) do
        sleep 0.02
        on 'ready'
      end
      assert_equal :total_timeout, result.reason
      assert_equal :wait_readable, peer.read_nonblock(1, exception: false)
    end
  end

end
