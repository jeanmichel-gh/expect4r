require 'expect4r/legacy'
require 'test/unit'
require 'rbconfig'
require 'timeout'
require 'shellwords'

# Real local PTYs; no routers or credentials required.
class TestInteraction < Test::Unit::TestCase
  def setup
    @session = Expect4r::BaseLoginObject.new(:ssh, host: 'unused.invalid')
  end

  def teardown
    @session.logout
    Expect4r::Base.all.delete(@session)
  end

  def spawn_ruby(code)
    @session.spawn([RbConfig.ruby, '-e', code].shelljoin)
  end

  def test_prompt_without_a_newline
    Timeout.timeout(5) do
      spawn_ruby('$stdout.sync = true; print "ready>"; sleep 10')
      output, status = @session.expect(/ready>/, 1)
      assert_equal :ok, status
      assert_equal 'ready>', output.last
    end
  end

  def test_pattern_response_exchange
    Timeout.timeout(5) do
      spawn_ruby('$stdout.sync = true; print "Name: "; name = gets.strip; print "Hello #{name}>"; sleep 10')
      output, status = @session.expect(/Hello Ruby>/, 1, [[/Name: /, 'Ruby']])
      assert_equal :ok, status
      assert_include output.join, 'Hello Ruby>'
    end
  end

  def test_silent_child_times_out
    Timeout.timeout(5) do
      spawn_ruby('sleep 10')
      assert_raise(Expect4r::ExpTimeoutError) { @session.expect(/never/, 0.05) }
    end
  end
end
