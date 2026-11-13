# frozen_string_literal: true
require_relative 'test_helper'
require 'expect4r_routers'
class RouterCapabilitiesTest < RouterApplicationTest
  FIXTURE = File.expand_path('fixtures/router_cli.rb', __dir__)
  def router(adapter: :ios, scenario: 'normal', fragment: false, **options, &block)
    args = [RbConfig.ruby, FIXTURE, "--adapter=#{adapter}", "--scenario=#{scenario}"]
    args << '--fragment' if fragment
    Expect4rRouters::Router.spawn(adapter, *args, user: 'lab', password: -> { 'secret' }, **options, &block)
  end
  def test_user_admin_and_enable_authentication
    router(scenario: 'user_mode', fragment: true) do |device|
      assert_equal :user, device.mode
      assert device.user?
      assert !device.admin?
      assert_nil device.config_depth
      device.enable(password: -> { 'enable-secret' })
      assert_equal :admin, device.mode
      assert device.admin?
      assert device.exec?
      assert device.in?(:exec)
      device.disable
      assert device.user?
      assert_raise(Expect4rRouters::AuthenticationError) { device.enable(password: 'wrong') }
      assert device.user?
    end
  end
  def test_cisco_configuration_depth_and_parent_navigation
    [:ios, :iox].each do |adapter|
      router(adapter:) do |device|
        device.configure do |config|
          assert device.config?
          assert_equal 0, device.config_depth
          assert_equal 1, device.config_lvl?
          config.command('router bgp 65000')
          assert_equal 1, device.config_depth
          config.command('address-family ipv4 unicast')
          assert_equal 2, device.config_depth
          assert_equal ['router bgp 65000', 'address-family ipv4 unicast'], device.config_path
          config.command('neighbor 192.0.2.1 activate')
          assert_equal 2, device.config_depth
          assert_raise(Expect4rRouters::CommandError) { config.command('bad command') }
          assert_equal 2, device.config_depth
          device.up
          assert_equal 1, device.config_depth
          device.top
          assert_equal 0, device.config_depth
          config.command('interface range GigabitEthernet0/1-4')
          assert_equal 1, device.config_depth # config-if-range is ONE level.
          assert_equal 'config-if-range', device.config_submode
        end
        assert device.admin?
        assert_nil device.config_depth
      end
    end
  end
  def test_unknown_cisco_context_never_guesses_depth
    router do |device|
      device.configure do |config|
        config.command('mystery-context')
        assert device.config?
        assert_nil device.config_depth
        assert !device.context_known?
        assert_raise(Expect4rRouters::ConfigurationError) { device.up }
      end
      assert device.admin?
    end
  end
  def test_junos_hierarchy_is_observed_from_edit_markers
    router(adapter: :junos, fragment: true) do |device|
      assert_equal :operational, device.mode
      assert device.operational?
      assert !device.admin? # Operational mode does not prove administrator rights.
      device.configure do |config|
        assert_equal 0, device.config_depth
        config.command('edit protocols bgp group EDGE')
        assert_equal 3, device.config_depth
        assert_equal ['protocols', 'bgp', 'group EDGE'], device.config_path
        config.command('set peer-as 65001')
        assert_equal 3, device.config_depth
        device.up
        assert_equal ['protocols', 'bgp'], device.config_path
        device.top
        assert_equal 0, device.config_depth
        config.command('edit interfaces ge-0/0/0 unit 0 family inet')
        assert_equal 4, device.config_depth
        assert_equal ['interfaces', 'ge-0/0/0', 'unit 0', 'family inet'], device.config_path
        config.commit
      end
      assert device.operational?
      assert_nil device.config_depth
    end
  end
  def test_junos_unknown_grammar_keeps_path_without_fabricated_depth
    router(adapter: :junos) do |device|
      device.configure do |config|
        config.command('edit exotic named-container')
        assert device.config?
        assert_nil device.config_depth
        assert_equal ['exotic', 'named-container'], device.config_path
        device.top
        assert_equal 0, device.config_depth
      end
    end
  end
  def test_direct_session_writes_invalidate_context_until_observed
    router do |device|
      assert device.admin?
      device.session.send_line('configure terminal')
      assert_equal :unknown, device.mode
      assert_nil device.config_depth
      device.resynchronize!
      assert device.config?
      assert_equal 0, device.config_depth
      device.exec!('end')
      assert device.admin?
    end
  end
  def test_show_and_ping_preserve_configuration_location
    [:ios, :iox, :junos].each do |adapter|
      router(adapter:) do |device|
        device.configure do |config|
          config.command(adapter == :junos ? 'edit protocols bgp group EDGE' : 'router bgp 65000')
          path = device.config_path
          assert_include device.show!('version').output, "Simulator #{adapter}"
          assert_equal path, device.config_path
          result = device.ping!('192.0.2.1', count: 3)
          assert_equal 3, result.transmitted
          assert_equal path, device.config_path
          assert device.config?
        end
      end
    end
  end
  def test_basic_ping_has_uniform_statistics
    [:ios, :iox, :junos].each do |adapter|
      router(adapter:) do |device|
        result = device.ping!('192.0.2.1')
        assert result.success?
        assert_equal 5, result.transmitted
        assert_equal 5, result.received
        assert_equal 0, result.loss_pct
        assert_equal 100, result.success_rate
        assert_equal adapter == :junos ? 2.5 : 2.0, result.rtt_avg
        assert result.frozen?
        assert result.output.frozen?
      end
    end
  end
  def test_cisco_extended_ping_and_legacy_option_aliases
    [:ios, :iox].each do |adapter|
      router(adapter:, fragment: true) do |device|
        result = device.ping!('192.0.2.1', repeat_count: 3, datagram_size: 1400,
                              source_address: 'Loopback0', timeout: 1, tos: 16, df: true,
                              pattern: '0xdead', pct_success: 100)
        assert_equal 3, result.transmitted
        assert_equal 3, result.received
        assert_include result.output, adapter == :ios ? 'Protocol [ip]' : 'Protocol [ipv4]'
        assert_include result.output, 'Loopback0'
        assert_include result.output, '1400'
      end
    end
  end
  def test_cisco_sweep_counts_actual_transmissions
    [:ios, :iox].each do |adapter|
      router(adapter:) do |device|
        result = device.ping!('192.0.2.1', count: 2, sweep_min_size: 100, sweep_max_size: 104, sweep_interval: 2)
        assert_equal 6, result.transmitted
        assert_equal 6, result.received
      end
    end
  end
  def test_junos_command_options_are_not_cisco_prompts
    router(adapter: :junos) do |device|
      result = device.ping!('2001:db8::1', count: 7, size: 1280, source: '2001:db8::2',
                            ttl: 16, wait: 2, interval: 0.1, df: true, routing_instance: 'BLUE', rapid: false)
      command = result.command_result.command
      assert_include command, 'inet6'
      assert_include command, 'count 7'
      assert_include command, 'routing-instance BLUE'
      assert_include command, 'do-not-fragment'
      assert_not_include command, 'rapid'
      assert_equal 7, result.transmitted
      assert_equal 0.75, result.rtt_stddev
    end
  end
  def test_packet_loss_threshold_and_error_callback
    [:ios, :iox, :junos].each do |adapter|
      router(adapter:, scenario: 'ping_loss') do |device|
        callback_result = nil
        result = device.ping('192.0.2.1', count: 5) { |failure| callback_result = failure }
        assert_equal :packet_loss, result.status
        assert_equal 5, result.transmitted
        assert_equal 3, result.received
        assert_equal 40, result.loss_pct
        assert_same result, callback_result
        assert device.ping!('192.0.2.1', minimum_success: 60).success?
        error = assert_raise(Expect4rRouters::PingError) { device.ping!('192.0.2.1', pct_success: 100) }
        assert_equal 3, error.result.received
        assert device.exec?
      end
    end
  end
  def test_total_loss_is_not_missing_statistics
    [:ios, :iox, :junos].each do |adapter|
      router(adapter:, scenario: 'ping_none') do |device|
        result = device.ping('192.0.2.1')
        assert_equal :packet_loss, result.status
        assert_equal 0, result.received
        assert_equal 100, result.loss_pct
        assert_nil result.rtt_avg
      end
    end
  end
  def test_unparseable_output_and_timeouts_are_distinct
    [:ios, :junos].each do |adapter|
      router(adapter:, scenario: 'ping_malformed') do |device|
        assert_equal :parse_error, device.ping('192.0.2.1').status
        assert_nil device.ping('192.0.2.1').received
      end
      router(adapter:, scenario: 'ping_timeout') do |device|
        assert_equal :timeout, device.ping('192.0.2.1', command_timeout: 0.02).status
        assert_equal :uncertain, device.state
        assert_equal :unknown, device.mode
      end
      router(adapter:, scenario: 'ping_disconnect') do |device|
        result = device.ping('192.0.2.1')
        assert_equal :eof, result.status
        assert_include result.output, 'ping interrupted'
      end
    end
  end
  def test_invalid_and_unsupported_options_are_rejected_before_sending
    [:ios, :iox, :junos].each do |adapter|
      router(adapter:) do |device|
        before = device.session.write_generation
        assert_raise(ArgumentError) { device.ping("192.0.2.1\nreload") }
        assert_raise(ArgumentError) { device.ping('192.0.2.1', count: 0) }
        assert_raise(ArgumentError) { device.ping('192.0.2.1', count: 2, repeat_count: 3) }
        assert_raise(ArgumentError) { device.ping('192.0.2.1', source: 'Loopback0;reload') }
        if adapter == :junos
          assert_raise(Expect4rRouters::UnsupportedOperation) { device.ping('192.0.2.1', probe_timeout: 2) }
          assert_raise(Expect4rRouters::UnsupportedOperation) { device.ping('192.0.2.1', sweep_max_size: 1500) }
        else
          assert_raise(Expect4rRouters::UnsupportedOperation) { device.ping('192.0.2.1', ttl: 16) }
        end
        assert_equal before, device.session.write_generation
      end
    end
  end
  def test_scoped_privilege_changes_restore_the_previous_mode
    router(scenario: 'user_mode') do |device|
      value = device.with_mode(:admin, password: 'enable-secret') do
        assert device.admin?
        :value
      end
      assert_equal :value, value
      assert device.user?
      device.enable(password: 'enable-secret')
      assert_raise(RuntimeError) do
        device.with_mode(:user, password: 'enable-secret') { raise 'application error' }
      end
      assert device.admin?
    end
  end

end
