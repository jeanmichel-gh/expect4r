# frozen_string_literal: true
require 'shellwords'
module Expect4rRouters
  class Router
    # Command history supplies information absent from Cisco's abbreviated prompt.
    # Junos markers are authoritative; supported grammar groups named statements.
    class Context
      attr_reader :mode, :path, :depth, :submode
      JUNOS_PAIRED = %w[group neighbor unit family address area interface policy-statement term instance service-set filter pool zone security-zone].freeze
      JUNOS_NODES = %w[system interfaces protocols bgp ospf ospf3 isis policy-options routing-options security firewall vlans chassis class-of-service routing-instances logical-systems groups inet inet6 unicast multicast forwarding-options static route-options].freeze
      def initialize(adapter)
        @adapter = adapter
        unknown!
      end
      def unknown!
        @mode, @path, @depth, @submode = :unknown, nil, nil, nil
      end
      def observe(prompt, command: nil, success: true, hierarchy: nil)
        previous_mode, previous_submode = @mode, @submode
        if @adapter == :junos
          @mode = prompt.rstrip.end_with?('#') ? :config : :operational
          @submode = @mode == :config ? 'edit' : nil
        elsif (match = /\((config[^)]*)\)[#>] ?\z/.match(prompt))
          @mode, @submode = :config, match[1]
        else
          @mode, @submode = prompt.rstrip.end_with?('>') ? :user : :admin, nil
        end
        unless @mode == :config
          @path = @depth = nil
          return
        end
        if @adapter == :junos
          observe_junos(command, success, hierarchy, previous_mode)
        elsif @submode == 'config'
          set_path([])
        elsif success && command
          observe_cisco(command, previous_mode, previous_submode)
        elsif @submode != previous_submode || previous_mode != :config
          @path = @depth = nil
        end
      end
      private
      def set_path(path)
        @path = path&.map { |item| String.new(item).freeze }&.freeze
        @depth = @path&.size
      end
      def observe_cisco(command, previous_mode, previous_submode)
        case command.strip
        when /\A(?:interface|router|line|route-map|policy-map|class-map|vrf definition|ip vrf)\s+.+\z/, 'control-plane'
          set_path([command])
        when /\Aaddress-family\s+.+\z/
          if @path && @path.first&.start_with?('router ')
            set_path([@path.first, command])
          else
            set_path(nil)
          end
        when /\Aclass\s+.+\z/
          @path&.first&.start_with?('policy-map ') ? set_path([@path.first, command]) : set_path(nil)
        when 'exit', 'exit-address-family'
          set_path(@path&.[](0...-1))
        else
          # Known leaf operations preserve context; an unexplained prompt change
          # or an unfamiliar command never invents a hierarchy.
          leaf = /\A(?:do |run |no |description(?: |$)|neighbor |network |redistribute |shutdown$|remote-as |activate$|bgp |ip |ipv4 |ipv6 |maximum-paths |log-adjacency-changes)/.match?(command)
          set_path(nil) unless leaf && previous_mode == :config && previous_submode == @submode
        end
      end
      def observe_junos(command, success, hierarchy, previous_mode)
        if hierarchy && (match = /\A\[edit(?: (.*))?\]\z/.match(hierarchy))
          tokens = Shellwords.shellsplit(match[1].to_s)
          levels, index, known = [], 0, true
          while index < tokens.size
            token = tokens[index]
            if JUNOS_PAIRED.include?(token)
              if tokens[index + 1]
                levels << "#{token} #{tokens[index + 1]}"
                index += 2
              else
                levels << token
                index += 1
              end
            elsif JUNOS_NODES.include?(token) || (index.positive? && %w[interfaces routing-instances logical-systems groups vlans].include?(tokens[index - 1]))
              levels << token
              index += 1
            else
              known = false
              break
            end
          end
          # Keep the exact marker available when its depth cannot be interpreted.
          if known
            set_path(levels)
          else
            @path, @depth = tokens.map(&:freeze).freeze, nil
          end
        elsif success && command&.match?(/\Aconfigur(?:e|ation)(?: |$)/)
          set_path([])
        elsif previous_mode != :config || (success && command&.match?(/\A(?:edit|up|top|exit)(?: |$)/))
          set_path(nil)
        end
      rescue ArgumentError
        set_path(nil)
      end
    end

    module Modes
      def mode
        refresh_context!
        @context.mode
      end
      def config? = mode == :config
      def user? = mode == :user
      def admin? = mode == :admin
      def operational? = mode == :operational
      def exec? = [:admin, :operational].include?(mode)
      def in?(value = nil) = value ? (value == :exec ? exec? : mode == value) : mode
      def config_lvl? = config? ? (config_depth && config_depth + 1) : -1
      def config_depth
        refresh_context!
        @context.depth
      end
      def config_path
        refresh_context!
        @context.path
      end
      def config_submode
        refresh_context!
        @context.submode
      end
      def context_known? = mode != :unknown && (!config? || !config_depth.nil?)
      def enable(password: nil, timeout: 10)
        raise UnsupportedOperation, 'enable is an IOS privilege transition' unless @adapter == :ios
        operation do
          return self if admin?
          raise ConfigurationError, 'enable requires user mode' unless user?
          replies = [[/Password: ?\z/i, password, true]]
          result = exec('enable', timeout:, replies:)
          raise AuthenticationError.new('enable did not reach privileged EXEC', result:) unless result.success? && admin?
          self
        end
      end
      def disable
        raise UnsupportedOperation, 'disable is an IOS privilege transition' unless @adapter == :ios
        operation do
          raise ConfigurationError, 'disable requires privileged EXEC' unless admin?
          exec!('disable')
          raise ConfigurationError, 'disable did not reach user EXEC' unless user?
          self
        end
      end
      def top
        operation do
          raise ConfigurationError, 'top requires configuration mode' unless config?
          if @adapter == :junos
            exec!('top')
          else
            raise ConfigurationError, 'unknown configuration depth; resynchronize first' if config_depth.nil?
            config_depth.times { exec!('exit') }
          end
          raise ConfigurationError, 'configuration root was not confirmed' unless config_depth == 0
          self
        end
      end
      def up(levels = 1)
        raise ArgumentError, 'levels must be a positive Integer' unless levels.is_a?(Integer) && levels.positive?
        operation do
          raise ConfigurationError, 'up requires a known configuration depth' unless config? && !config_depth.nil?
          count = [levels, config_depth].min
          if count.positive?
            @adapter == :junos ? exec!("up #{count}") : count.times { exec!('exit') }
          end
          self
        end
      end
      def with_mode(target, password: nil)
        raise ArgumentError, 'with_mode requires a block' unless block_given?
        operation do
          original = mode
          raise ConfigurationError, 'unknown starting mode' if original == :unknown
          if target == :config && !config?
            configure { |scope| yield scope }
          elsif target == original || (target == :exec && exec?)
            yield self
          elsif @adapter == :ios && [:user, :admin].include?(original) && [:user, :admin].include?(target)
            target == :admin ? enable(password:) : disable
            failed = false
            begin
              yield self
            rescue Exception
              failed = true
              raise
            ensure
              begin
                raise ConfigurationError, 'cannot restore an uncertain privilege context' unless @state == :ready
                original == :admin ? enable(password:) : disable
              rescue StandardError => error
                @session.cleanup_errors << error
                @state = :uncertain
                invalidate_context!
                raise unless failed
              end
            end
          else
            raise UnsupportedOperation, 'transition would discard configuration or is not supported'
          end
        end
      end
      private
      def refresh_context!
        if @state != :ready || @context_generation != @session.write_generation
          @context.unknown!
        end
      end
      def observe_context(prompt, command: nil, success: true, hierarchy: nil)
        @context.observe(prompt, command:, success:, hierarchy:)
        @mode = @context.mode
        @context_generation = @session.write_generation
      end
      def invalidate_context!
        @context.unknown!
        @mode = :unknown
      end
    end
  end
end
