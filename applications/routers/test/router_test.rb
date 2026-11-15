# frozen_string_literal: true
require_relative 'test_helper'
require 'expect4r_routers'
class RouterTest < RouterApplicationTest
  FIXTURE = File.expand_path('fixtures/router_cli.rb', __dir__)
  def router(adapter: :ios, scenario: 'normal', fragment: false, **options, &block)
    argv = [RbConfig.ruby, FIXTURE, "--adapter=#{adapter}", "--scenario=#{scenario}"]
    argv << '--fragment' if fragment
    Expect4rRouters::Router.spawn(adapter, *argv, user: 'lab', password: -> { 'secret' }, **options, &block)
  end
  def test_login_and_exact_output_with_fragmented_prompts
    router(fragment: true) do |device|
      result = device.exec!('show version', timeout: 3)
      assert_equal "Simulator ios\r\n  quoted spaces stay   here\r\n\r\nBuild 42\r\n", result.output
      assert_equal :admin, result.mode_before
      assert_equal :admin, result.mode_after
      assert_equal 'router#', result.prompt
      assert result.success?
    end
  end
  def test_paging_preserves_the_whole_response
    router do |device|
      result = device.exec!('show paged')
      assert_equal "page 1\r\npage 2\r\npage 3\r\n", result.output
      assert_equal result.output.bytesize, result.output_bytes
    end
  end
  def test_errors_and_command_sequences
    router do |device|
      assert_equal :device_error, device.exec('bad command').status
      assert_raise(Expect4rRouters::CommandError) { device.exec!('bad command') }
      results = device.exec_many(['show version', 'bad command', 'show version'])
      assert_equal 2, results.size
      error = assert_raise(Expect4rRouters::CommandError) { device.exec_many!(['show version', 'bad command']) }
      assert_equal 2, error.progress.size
      assert_raise(ArgumentError) { device.exec("show version\nreload") }
    end
  end
  def test_output_sink_and_capture_limit
    router(capture_limit: 16) do |device|
      sink = StringIO.new
      result = device.exec!('show large', output: sink)
      assert_nil result.output
      assert_equal 1000, sink.string.lines.size
      assert_equal sink.string.bytesize, result.output_bytes
      assert_raise(Expect4rRouters::OutputLimitError) { device.exec('show version') }
      assert_equal :uncertain, device.state
    end
  end
  def test_timeout_blocks_commands_until_explicit_resynchronization
    router do |device|
      result = device.exec('show slow', timeout: 0.03)
      assert_equal :timeout, result.status
      assert_equal "partial output\r\n", result.output
      assert_equal :uncertain, device.state
      assert_raise(Expect4rRouters::CommandError) { device.exec('show version') }
      device.resynchronize!(timeout: 1)
      assert_equal :ready, device.state
      assert device.exec!('show version').success?
    end
  end
  def test_disconnect_has_partial_output
    router do |device|
      result = device.exec('show disconnect')
      assert_equal :eof, result.status
      assert_equal 'partial output', result.output
      assert_equal :uncertain, device.state
    end
  end
  def test_authentication_and_host_key_failures
    assert_raise(Expect4rRouters::AuthenticationError) do
      Expect4rRouters::Router.spawn(:ios, RbConfig.ruby, FIXTURE, user: 'lab', password: 'wrong')
    end
    assert_raise(Expect4rRouters::HostKeyError) { router(scenario: 'host_key') {} }
  end
  def test_ios_configuration_is_applied_immediately_and_restores_mode
    router do |device|
      result = device.configure do |config|
        config.command 'description "spaces   kept"'
        assert_raise(Expect4rRouters::UnsupportedOperation) { config.commit }
      end
      assert_equal :admin, result.mode
      assert_equal 1, result.commands.size
      assert_include device.exec!('show running-config').output, 'description "spaces   kept"'
      assert_raise(Expect4rRouters::CommandError) do
        device.configure { |config| config.command 'first applied'; config.command 'bad command' }
      end
      assert_equal :admin, device.mode
      assert_include device.exec!('show running-config').output, 'first applied'
    end
  end
  def test_junos_commit_and_discard
    router(adapter: :junos) do |device|
      result = device.configure { |config| config.command 'set system host-name test'; config.commit }
      assert result.commit.success?
      assert_include device.exec!('show configuration').output, 'set system host-name test'
      device.configure { |config| config.command 'set system host-name discarded' }
      assert_not_include device.exec!('show configuration').output, 'discarded'
      assert_equal :operational, device.mode
    end
  end
  def test_failed_commit_and_lock_do_not_leave_config_mode
    router(adapter: :junos, scenario: 'commit_failure') do |device|
      assert_raise(Expect4rRouters::CommandError) do
        device.configure { |config| config.command 'set bad config'; config.commit }
      end
      assert_equal :operational, device.mode
      assert_not_include device.exec!('show configuration').output, 'set bad config'
    end
    router(adapter: :junos, scenario: 'locked') do |device|
      assert_raise(Expect4rRouters::CommandError) { device.configure { raise 'should not enter' } }
      assert_equal :operational, device.mode
    end
  end

  def test_ios_xr_candidate_commit_and_abort_restore_exec
    router(adapter: :iox) do |device|
      device.configure { |config| config.command 'description committed'; config.commit }
      assert_include device.exec!('show running-config').output, 'description committed'
      device.configure { |config| config.command 'description discarded' }
      assert_not_include device.exec!('show running-config').output, 'discarded'
      assert_equal :admin, device.mode
    end
  end

  def test_streaming_capture_sink_failure_reports_progress_and_marks_uncertain
    sink = Class.new do
      attr_reader :data
      def initialize = (@data = ''.b)
      def write(bytes)
        raise IOError, 'sink failed' unless @data.empty?
        @data << bytes.byteslice(0, 2)
        2
      end
    end.new
    router do |device|
      error = assert_raise(Expect4r::CaptureSinkError) { device.exec!('show version', output: sink) }
      assert_equal 2, error.progress[:sink_bytes]
      assert_equal 2, sink.data.bytesize
      assert_equal :uncertain, device.state
      assert_kind_of IOError, error.cause
    end
  end

  def test_router_modes_paging_and_ping_round_trip_through_recording
    [:ios, :iox, :junos].each do |adapter|
      recording = StringIO.new
      exercise = lambda do |device|
        text = device.show!('paged').output
        depth = nil
        device.configure do |config|
          config.command(adapter == :junos ? 'edit protocols bgp group EDGE' : 'router bgp 65000')
          depth = device.config_depth
        end
        result = device.ping('192.0.2.1')
        [text, depth, result.status, result.transmitted, result.received, device.mode]
      end
      original = nil
      router(adapter:, recording:) { |device| original = exercise.call(device) }
      trace = Expect4r::ReplayTrace.load(StringIO.new(recording.string))
      substitutions = trace.redactions.to_h do |span|
        value = span[:bytes] == 7 ? "secret\r" : 'secret'
        [[span[:direction], span[:stream_offset]], value]
      end
      Expect4r.replay(trace, substitutions:, fragment_size: 1) do |session|
        device = Expect4rRouters::Router.new(session, adapter:, capture_limit: 8_388_608, prompt: nil)
        device.login(user: 'lab', password: -> { 'secret' }, timeout: 3, attempts: 3)
        device.exec!(device.policy.fetch(:paging))
        assert_equal original, exercise.call(device)
        assert session.verify_replay!
      end
    end
  end

  def test_fragmented_pager_control_spaces_preserve_real_indentation
    capture = Expect4rRouters::Router::Capture.new('show', sink: nil, limit: 1000)
    capture.append("show\r\npage 1\r\n")
    capture.leading_spaces(' ')
    capture.pager('--More--')
    capture.leading_spaces('   ') # One control space, two real indentation spaces.
    capture.append("page 2\r\n")
    capture.pager('--More--') # Bare marker has no implied trailing control space.
    capture.leading_spaces('  ')
    capture.append("page 3\r\n")
    capture.leading_spaces(' ')
    capture.pager('---(more)---') # Junos marker does not own preceding output space.
    capture.append("page 4\r\n")
    capture.finish
    assert_equal "page 1\r\n  page 2\r\n  page 3\r\n page 4\r\n", capture.output
  end

end
