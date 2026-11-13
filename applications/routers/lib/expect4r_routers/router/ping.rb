# frozen_string_literal: true
module Expect4rRouters
  PingResult = Data.define(:target, :status, :transmitted, :received, :success_rate, :loss_pct,
                          :rtt_min, :rtt_avg, :rtt_max, :rtt_stddev, :minimum_success,
                          :output, :command_result) do
    def success? = status == :ok
    def inspect = "#<Expect4rRouters::PingResult status=#{status} transmitted=#{transmitted.inspect} received=#{received.inspect}>"
    alias to_s inspect
  end
  class PingError < Error; end
  class Router
    class PingOptions
      ALIASES = { repeat_count: :count, datagram_size: :size, source_address: :source,
                  pct_success: :minimum_success, min_success: :minimum_success, timeout: :probe_timeout }.freeze
      COMMON = %i[count size source protocol minimum_success command_timeout].freeze
      CISCO = (COMMON + %i[probe_timeout tos df pattern sweep_min_size sweep_max_size sweep_interval]).freeze
      JUNOS = (COMMON + %i[rapid wait ttl tos df pattern interval logical_router logical_system routing_instance]).freeze
      attr_reader :values, :provided
      def initialize(adapter, target, options)
        @provided = {}
        options.each do |key, value|
          canonical = ALIASES.fetch(key, key)
          raise ArgumentError, "duplicate ping option #{canonical}" if @provided.key?(canonical)
          @provided[canonical] = value
        end
        known = CISCO | JUNOS
        raise ArgumentError, "unknown ping options: #{(@provided.keys - known).join(', ')}" unless (@provided.keys - known).empty?
        allowed = adapter == :junos ? JUNOS : CISCO
        unsupported = @provided.keys - allowed
        raise UnsupportedOperation, "#{adapter} ping does not support #{unsupported.join(', ')}" unless unsupported.empty?
        @values = { count: 5, minimum_success: 99, command_timeout: 30,
                    protocol: target.include?(':') ? :ipv6 : :ipv4 }.merge(@provided)
        @values[:protocol] = case @values[:protocol].to_s
                             when 'ip', 'ipv4', 'inet' then :ipv4
                             when 'ipv6', 'inet6' then :ipv6
                             else raise ArgumentError, 'ping protocol must be IPv4 or IPv6'
                             end
        integer(:count, 1..2_000_000_000)
        integer(:size, 1..65_535)
        integer(:probe_timeout, 1..3600)
        integer(:ttl, 1..255)
        integer(:tos, 0..255)
        %i[sweep_min_size sweep_max_size sweep_interval].each { |key| integer(key, 1..65_535) }
        if @values[:sweep_min_size] && @values[:sweep_max_size] && @values[:sweep_min_size] > @values[:sweep_max_size]
          raise ArgumentError, 'sweep minimum exceeds maximum'
        end
        %i[df rapid].each do |key|
          raise ArgumentError, "#{key} must be boolean" if @values.key?(key) && ![true, false].include?(@values[key])
        end
        %i[wait interval].each do |key|
          next unless @values.key?(key)
          value = Expect4r.duration(@values[key])
          raise ArgumentError, "#{key} must be finite" unless value
          @values[key] = value
        end
        threshold = @values[:minimum_success]
        unless threshold.is_a?(Numeric) && !threshold.is_a?(Complex) && threshold.finite? && (0..100).cover?(threshold)
          raise ArgumentError, 'minimum_success must be between 0 and 100'
        end
        @values[:command_timeout] = Expect4r.duration(@values[:command_timeout])
        %i[source logical_router logical_system routing_instance].each do |key|
          @values[key] = self.class.token(@values[key], key.to_s) if @values.key?(key)
        end
        if @values[:logical_router] && @values[:logical_system]
          raise ArgumentError, 'choose logical_router or logical_system'
        end
        if @values[:pattern] && !(/\A(?:0[xX])?[0-9a-fA-F]{1,32}\z/.match?(@values[:pattern].to_s))
          raise ArgumentError, 'pattern must be hexadecimal'
        end
        if @values[:protocol] == :ipv6 && @values[:df] && adapter != :junos
          raise UnsupportedOperation, 'Cisco IPv6 ping has no IPv4 DF bit'
        end
        @values.freeze
        @provided.freeze
      end
      def self.token(value, name)
        unless value.is_a?(String) && /\A[A-Za-z0-9_:][A-Za-z0-9_.:%\/+\-]*\z/.match?(value)
          raise ArgumentError, "#{name} must be one CLI token without command separators"
        end
        String.new(value).freeze
      end
      def [](key) = @values[key]
      private
      def integer(key, range)
        return unless @values.key?(key)
        value = @values[key]
        raise ArgumentError, "#{key} must be an Integer in #{range}" unless value.is_a?(Integer) && range.cover?(value)
      end
    end

    module Drivers
      Plan = Data.define(:command, :replies)
      class CiscoIOS
        def protocol_name(protocol) = protocol == :ipv4 ? 'ip' : 'ipv6'
        def ping_plan(target, options)
          interactive = (options.provided.keys & %i[count size source probe_timeout tos df pattern sweep_min_size sweep_max_size sweep_interval]).any?
          unless interactive
            family = options[:protocol] == :ipv6 ? ' ipv6' : ''
            return Plan.new(command: "ping#{family} #{target}", replies: [].freeze)
          end
          extended = %i[source tos df pattern].any? { |key| options.values.key?(key) }
          sweep = %i[sweep_min_size sweep_max_size sweep_interval].any? { |key| options.values.key?(key) }
          reply = ->(key) { options[key].nil? ? '' : options[key].to_s }
          replies = [
            [/Protocol[^\r\n]*: ?\z/i, protocol_name(options[:protocol]), false],
            [/Target (?:IP(?:v[46])? )?address[^\r\n]*: ?\z/i, target, false],
            [/Repeat count[^\r\n]*: ?\z/i, reply.call(:count), false],
            [/Datagram size[^\r\n]*: ?\z/i, reply.call(:size), false],
            [/Timeout[^\r\n]*: ?\z/i, reply.call(:probe_timeout), false],
            [/Extended commands[^\r\n]*: ?\z/i, extended ? 'yes' : 'no', false],
            [/Source address or interface[^\r\n]*: ?\z/i, reply.call(:source), false],
            [/(?:Type of service|Traffic class)[^\r\n]*: ?\z/i, reply.call(:tos), false],
            [/Set DF bit[^\r\n]*: ?\z/i, options[:df] ? 'yes' : 'no', false],
            [/Validate reply[^\r\n]*: ?\z/i, 'no', false],
            [/Data pattern[^\r\n]*: ?\z/i, reply.call(:pattern), false],
            [/Loose, Strict,[^\r\n]*: ?\z/i, '', false],
            [/Sweep range of sizes[^\r\n]*: ?\z/i, sweep ? 'yes' : 'no', false],
            [/Sweep min size[^\r\n]*: ?\z/i, reply.call(:sweep_min_size), false],
            [/Sweep max size[^\r\n]*: ?\z/i, reply.call(:sweep_max_size), false],
            [/Sweep interval[^\r\n]*: ?\z/i, reply.call(:sweep_interval), false]
          ]
          Plan.new(command: 'ping', replies: replies.map(&:freeze).freeze)
        end
      end
      class CiscoXR < CiscoIOS
        def protocol_name(protocol) = protocol.to_s
      end
      class Junos
        def ping_plan(target, options)
          parts = ['ping', target]
          parts << (options[:protocol] == :ipv6 ? 'inet6' : 'inet')
          parts << 'rapid' if options.values.fetch(:rapid, true)
          parts += ['count', options[:count].to_s]
          { size: 'size', source: 'source', tos: 'tos', ttl: 'ttl', pattern: 'pattern',
            interval: 'interval', wait: 'wait', logical_router: 'logical-router',
            logical_system: 'logical-system', routing_instance: 'routing-instance' }.each do |key, keyword|
            parts += [keyword, options[key].to_s] unless options[key].nil?
          end
          parts << 'do-not-fragment' if options[:df]
          Plan.new(command: parts.join(' '), replies: [].freeze)
        end
      end
    end

    module Ping
      def ping(target, **options)
        target = PingOptions.token(target, 'target')
        parsed = PingOptions.new(@adapter, target, options)
        driver = { ios: Drivers::CiscoIOS, iox: Drivers::CiscoXR, junos: Drivers::Junos }.fetch(@adapter).new
        plan = driver.ping_plan(target, parsed)
        operation do
          unless exec? || config?
            raise ConfigurationError, 'ping requires privileged EXEC or Junos operational context'
          end
          if config?
            prefix = @adapter == :junos ? 'run' : 'do'
            plan = Drivers::Plan.new(command: "#{prefix} #{plan.command}", replies: plan.replies)
          end
          command = exec(plan.command, timeout: parsed[:command_timeout], total_timeout: parsed[:command_timeout], replies: plan.replies)
          result = ping_result(target, command, parsed[:minimum_success])
          yield result if block_given? && !result.success?
          result
        end
      end
      def ping!(target, **options, &block)
        result = ping(target, **options, &block)
        raise PingError.new("ping ended with #{result.status}", result:, command: result.command_result.command) unless result.success?
        result
      end
      private
      def ping_result(target, command, minimum)
        output = command.output
        if @adapter == :junos
          statistics = /(\d+) packets transmitted, (\d+) (?:packets )?received, [\d.]+% packet loss/.match(output)
          tx, rx = statistics && [statistics[1].to_i, statistics[2].to_i]
        else
          statistics = /Success rate is [\d.]+ percent \((\d+)\/(\d+)\)/.match(output)
          rx, tx = statistics && [statistics[1].to_i, statistics[2].to_i]
        end
        valid = tx && tx.positive? && rx >= 0 && rx <= tx
        success_rate = valid ? 100.0 * rx / tx : nil
        rtt = /round-trip min\/avg\/max(?:\/stddev)?\s*=\s*([\d.]+)\/([\d.]+)\/([\d.]+)(?:\/([\d.]+))?\s*ms/.match(output)
        timings = rtt ? rtt.captures.map { |value| value&.to_f } : [nil] * 4
        status = if !command.success?
                   command.status
                 elsif !valid
                   :parse_error
                 elsif success_rate < minimum
                   :packet_loss
                 else
                   :ok
                 end
        PingResult.new(target:, status:, transmitted: valid ? tx : nil, received: valid ? rx : nil,
                       success_rate:, loss_pct: valid ? 100 - success_rate : nil,
                       rtt_min: timings[0], rtt_avg: timings[1], rtt_max: timings[2], rtt_stddev: timings[3],
                       minimum_success: minimum, output:, command_result: command)
      end
    end
  end
end
