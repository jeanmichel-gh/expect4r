# frozen_string_literal: true
require 'expect4r'
require_relative 'errors'
require 'monitor'
module Expect4rRouters
  CommandResult = Data.define(:command, :status, :output, :prompt, :duration, :mode_before,
                             :mode_after, :error, :output_bytes, :truncated) do
    def success? = status == :ok
    def inspect = "#<Expect4rRouters::CommandResult status=#{status} output_bytes=#{output_bytes}>"
    alias to_s inspect
  end
  ConfigurationResult = Data.define(:commands, :commit, :mode)

  # Router policies sit above the public session/matcher API. No vendor parsing
  # is used by the simulator, and no matcher state is changed by a router.
  class Router
    attr_reader :session, :state, :last_result
    ADAPTERS = {
      ios: { paging: 'terminal length 0', enter: 'configure terminal', leave: 'end', candidate: false },
      iox: { paging: 'terminal length 0', enter: 'configure exclusive', leave: 'end', candidate: true, discard: 'abort' },
      junos: { paging: 'set cli screen-length 0', enter: 'configure exclusive', leave: 'exit', candidate: true, discard: 'rollback 0' }
    }.freeze
    class << self
      def open(adapter, host:, user: nil, password: nil, port: 22, ssh: {}, **settings, &block)
        raise ArgumentError, 'unsupported SSH settings' unless (ssh.keys - [:host_key_policy, :identity]).empty?
        raise ArgumentError, 'host key policy must be strict' unless ssh.fetch(:host_key_policy, :strict) == :strict
        raise ArgumentError, 'invalid host' unless host.is_a?(String) && !host.empty? && !host.start_with?('-') && !host.include?("\0")
        raise ArgumentError, 'port must be between 1 and 65535' unless port.is_a?(Integer) && (1..65_535).cover?(port)
        argv = ['ssh', '-tt', '-o', 'StrictHostKeyChecking=yes', '-p', port.to_s]
        argv += ['-l', user] if user
        argv += ['-i', ssh[:identity]] if ssh[:identity]
        spawn(adapter, *argv, '--', host, user:, password:, **settings, &block)
      end
      def spawn(adapter, *argv, user: nil, password: nil, login_timeout: 30, attempts: 3,
                prompt: nil, disable_paging: true, capture_limit: 8_388_608, **settings)
        validate_adapter(adapter)
        session = Expect4r.spawn(*argv, **settings)
        handed_off, failed = false, false
        begin
          router = new(session, adapter:, capture_limit:, prompt:)
          router.login(user:, password:, timeout: login_timeout, attempts:)
          router.exec!(router.policy.fetch(:paging)) if disable_paging
          unless block_given?
            handed_off = true
            return router
          end
          yield router
        rescue Exception # Cleanup must also preserve interrupts and nonlocal block exits.
          failed = true
          raise
        ensure
          unless handed_off
            begin
              session.close
            rescue StandardError
              raise unless failed
            end
          end
        end
      end
      def attach(session, adapter: :ios, prompt:, capture_limit: 8_388_608)
        validate_adapter(adapter)
        router = new(session, adapter:, capture_limit:, prompt:)
        router.establish_prompt!(prompt)
        router
      end
      private
      def validate_adapter(adapter)
        raise ArgumentError, 'adapter must be :ios, :iox or :junos' unless ADAPTERS.key?(adapter)
      end
    end
    attr_reader :policy
    def initialize(session, adapter:, capture_limit:, prompt:)
      unless capture_limit.is_a?(Integer) && capture_limit.positive?
        raise ArgumentError, 'capture_limit must be positive'
      end
      @session, @adapter, @policy = session, adapter, ADAPTERS.fetch(adapter)
      @capture_limit, @initial_prompt = capture_limit, prompt
      @mode, @state = :unknown, :connecting
      @context = Context.new(adapter)
      @gate = Monitor.new
    end
    def capabilities = { candidate_config: @policy.fetch(:candidate), exclusive_config: @policy.fetch(:candidate) }.freeze
    def candidate_config? = capabilities.fetch(:candidate_config)
    def close
      operation { @session.close; @state = :closed }
    end
    def establish_prompt!(text)
      raise ArgumentError, 'prompt must be a nonempty String ending in > or #' unless text.is_a?(String) && /[>#] ?\z/.match?(text)
      @prompt = String.new(text).b.freeze
      label = text.sub(/(?:\(config[^)]*\))?[>#] ?\z/, '')
      suffix = text.end_with?(' ') ? ' ' : ''
      if @adapter == :junos
        @prompt_pattern = /(?:\A|(?<=\n))#{Regexp.escape(label)}[>#]#{Regexp.escape(suffix)}\z/n
      else
        @prompt_pattern = /(?:\A|(?<=\n))#{Regexp.escape(label)}(?:\(config[^)]*\))?[>#]#{Regexp.escape(suffix)}\z/n
      end
      observe_context(text)
      @state = :ready
    end
    def login(user:, password:, timeout:, attempts:)
      timeout = Expect4r.duration(timeout)
      raise ArgumentError, 'login timeout must be finite' if timeout.nil?
      raise ArgumentError, 'attempts must be positive' unless attempts.is_a?(Integer) && attempts.positive?
      router, challenges = self, 0
      operation do
        result = @session.expect(timeout:, total_timeout: timeout) do |patterns|
          patterns.on(/(?:Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED)/i) { raise HostKeyError, 'SSH host-key verification failed' }
          patterns.on(/(?:Permission denied|Authentication failed|Login incorrect)/i) { raise AuthenticationError, 'authentication rejected' }
          patterns.on(/(?:Username|login): ?\z/i) do
            raise AuthenticationError, 'username required' unless user.is_a?(String)
            send_line(user)
            exp_continue(reset_timeout: false)
          end
          patterns.on(/Password: ?\z/i) do
            challenges += 1
            raise AuthenticationError, 'password attempt limit reached' if challenges > attempts
            secret = password.respond_to?(:call) ? password.call : password
            raise AuthenticationError, 'password required' unless secret.is_a?(String)
            send_line(secret, sensitive: true)
            exp_continue(reset_timeout: false)
          end
          patterns.on(router.login_pattern, name: :prompt)
        end
        raise AuthenticationError.new('login did not reach a prompt', result:) unless result.matched?
        router.establish_prompt!(@initial_prompt || result.captures.first)
      end
      self
    end
    def exec(command, timeout: 30, idle_timeout: nil, total_timeout: nil, output: nil, replies: [])
      raise TypeError, 'command must be a String' unless command.is_a?(String)
      raise ArgumentError, 'command contains CR or LF' if command.match?(/[\r\n]/)
      raise TypeError, 'output must support write' if output && !output.respond_to?(:write)
      [timeout, idle_timeout, total_timeout].each { |value| Expect4r.duration(value) }
      unless replies.is_a?(Array) && replies.all? { |r| r.is_a?(Array) && r.size == 3 &&
        (r[0].is_a?(Regexp) || (r[0].is_a?(String) && !r[0].empty?)) &&
        (r[1].nil? || r[1].is_a?(String) || r[1].respond_to?(:call)) && [true, false].include?(r[2]) }
        raise ArgumentError, 'replies must contain [pattern, response, sensitive] triples'
      end
      operation do
        raise CommandError, "router state is #{@state}; resynchronize or reconnect first" unless @state == :ready
        started, before_mode = Expect4r.monotonic, mode
        accumulator = Capture.new(command, sink: output, limit: @capture_limit)
        router = self
        begin
          written = @session.send_line(command)
          result = @session.expect(timeout:, idle_timeout:, total_timeout:) do |patterns|
            patterns.on(/(?: --More-- |--More--|---\(more(?: \d+%)?\)---)/n, name: :pager, limit: 100) do |event|
              accumulator.append(event.before)
              write ' '
              exp_continue(reset_timeout: false)
            end
            replies.each_with_index do |(pattern, response, sensitive), index|
              patterns.on(pattern, name: :"response_#{index}", limit: 8) do |event|
                accumulator.append(event.before + event.match)
                value = response.respond_to?(:call) ? response.call : response
                raise AuthenticationError, 'response requires a String' unless value.is_a?(String)
                send_line(value, sensitive: !!sensitive)
                exp_continue(reset_timeout: false)
              end
            end
            patterns.on(router.prompt_pattern, name: :prompt)
            patterns.on(/[^\n]*\n/n, name: :line) do |event|
              accumulator.append(event.before + event.match)
              exp_continue(reset_timeout: false)
            end
          end
          accumulator.append(result.before)
          accumulator.finish
          status = result.matched? ? (accumulator.device_error? ? :device_error : :ok) : result.status
          if result.matched?
            @prompt = result.match
            observe_context(@prompt, command:, success: status == :ok, hierarchy: accumulator.hierarchy)
          else
            @state = :uncertain
            invalidate_context!
          end
          error = case status
                  when :device_error then CommandError.new('device rejected command', command:)
                  when :timeout then CommandTimeout.new('command timed out; execution outcome unknown', command:, result:, bytes_written: written)
                  when :eof then ConnectionLost.new('connection ended during command', command:, result:)
                  end
          @last_result = CommandResult.new(command: command.dup.freeze, status:, output: accumulator.output,
                                          prompt: result.match, duration: Expect4r.monotonic - started,
                                          mode_before: before_mode, mode_after: @mode, error:,
                                          output_bytes: accumulator.bytes, truncated: false)
        rescue StandardError
          @state = :uncertain
          invalidate_context!
          raise
        end
      end
    end
    def exec!(command, **options)
      result = exec(command, **options)
      raise result.error.class.new(result.error.message, command: result.command, result:, bytes_written: result.error.bytes_written) unless result.success?
      result
    end
    def show(command = '', **options)
      raise TypeError, 'show argument must be a String' unless command.is_a?(String)
      raise ArgumentError, 'show accepts one line' if command.match?(/[\r\n]/)
      operation do
        prefix = config? ? (@adapter == :junos ? 'run ' : 'do ') : ''
        exec("#{prefix}show#{command.empty? ? '' : ' ' + command}", **options)
      end
    end
    def show!(command = '', **options)
      result = show(command, **options)
      raise result.error.class.new(result.error.message, result:) unless result.success?
      result
    end
    def exec_many(commands, **options)
      validate_commands(commands)
      operation do
        commands.each_with_object([]) do |command, results|
          result = exec(command, **options)
          results << result
          break results.freeze unless result.success?
        end.freeze
      end
    end
    def exec_many!(commands, **options)
      results = exec_many(commands, **options)
      failure = results.find { |r| !r.success? }
      raise failure.error.class.new(failure.error.message, result: failure, progress: results) if failure
      results
    end
    def resynchronize!(timeout: 5)
      operation do
        raise ConnectionLost, 'input has ended' if @session.eof?
        @session.clear_buffer
        @session.write("\x03")
        @session.send_line
        result = @session.expect!(@prompt_pattern, timeout:)
        observe_context(result.match, hierarchy: result.before.lines.map(&:strip).reject(&:empty?).last)
        @state = :ready
        result
      rescue StandardError
        @state = :uncertain
        raise
      end
    end
    def configure
      raise ArgumentError, 'configure needs a block' unless block_given?
      operation do
        raise ConfigurationError, 'configuration requires exec mode' unless exec?
        exec!(@policy.fetch(:enter))
        raise ConfigurationError, 'failed to enter config mode' unless @mode == :config
        scope = Configuration.new(self)
        failure = nil
        begin
          yield scope
        rescue Exception => error
          failure = error
          raise
        ensure
          begin
            if @state == :ready
              exec!('top') if @adapter == :junos && config?
              exec!(@policy.fetch(:discard)) if candidate_config?
              exec!(@policy.fetch(:leave)) if @mode == :config
            else
              raise ConfigurationError, 'cannot safely restore an uncertain configuration session'
            end
          rescue StandardError => cleanup_error
            @state = :uncertain
            invalidate_context!
            if failure
              @session.cleanup_errors << cleanup_error
            else
              raise
            end
          end
        end
        ConfigurationResult.new(commands: scope.commands.freeze, commit: scope.commit_result, mode: @mode)
      end
    end
    def login_pattern
      return /(?:\A|(?<=\n))(#{Regexp.escape(@initial_prompt)})\z/n if @initial_prompt
      # IOS normally ends exactly at '#'; Junos has a mandatory trailing space.
      suffix = @adapter == :junos ? ' ' : ''
      /(?:\A|(?<=\n))([-\w.@:\/]+(?:\(config[^)]*\))?[>#]#{suffix})\z/n
    end
    def prompt_pattern = @prompt_pattern
    private
    def operation
      raise BusySessionError, 'router has an active operation' unless @gate.try_enter
      begin
        @session.with_lease { yield }
      ensure
        @gate.exit
      end
    end
    def validate_commands(commands)
      unless commands.is_a?(Array) && commands.all? { |s| s.is_a?(String) && !s.match?(/[\r\n]/) }
        raise ArgumentError, 'commands must be an Array of single-line Strings'
      end
    end

    class Configuration
      attr_reader :commands, :commit_result
      def initialize(router)
        @router, @commands = router, []
      end
      def command(text)
        result = @router.exec(text)
        @commands << result
        raise CommandError.new('configuration command failed', result:, progress: @commands.dup.freeze) unless result.success?
        result
      end
      def commit
        raise UnsupportedOperation, 'this device applies commands immediately' unless @router.candidate_config?
        @commit_result = @router.exec!('commit')
      end
    end

    # Keeps command output across paging and line matches. Echo removal is
    # confined to the first exact command line; all other whitespace is retained.
    class Capture
      def bytes = @storage.bytes
      def hierarchy
        line = @last_line.to_s.strip
        line if /\A\[edit(?: [^\]]*)?\]\z/.match?(line)
      end
      def initialize(command, sink:, limit:)
        @echo = command.b
        @sink = sink
        @storage = Expect4r::Capture.new(sink:, limit: sink ? nil : limit, retain: sink ? 0 : nil)
        @prefix, @error = ''.b, false
        @echo_pending = true
        @line_tail = ''.b
      end
      def append(bytes)
        if @echo_pending
          @prefix << bytes
          return unless (endline = @prefix.index("\n"))
          first = @prefix.byteslice(0, endline + 1)
          rest = @prefix.byteslice(endline + 1..)
          @echo_pending = false
          emit(first) unless first.delete_suffix("\n").delete_suffix("\r") == @echo
          @prefix = ''.b
          emit(rest)
        else
          emit(bytes)
        end
      end
      def finish
        @echo_pending = false
        emit(@prefix)
        @prefix = ''.b
      end
      def output = @sink ? nil : @storage.output
      def device_error? = @error
      private
      def emit(bytes)
        return if bytes.empty?
        text = @line_tail + bytes
        lines = text.split("\n", -1)
        @line_tail = lines.pop
        lines.each { |line| @last_line = line unless line.strip.empty? }
        @last_line = @line_tail unless @line_tail.strip.empty?
        @error ||= /(?:\A|\n)(?:% (?:Invalid|Error|Bad)|error:|syntax error)/i.match?(bytes)
        @storage.append(bytes)
      rescue Expect4r::CaptureLimitError => error
        raise OutputLimitError.new('command output limit exceeded', command: @echo, progress: @storage.output), cause: error
      end
    end
  end
end

require_relative 'router/context'
Expect4rRouters::Router.include(Expect4rRouters::Router::Modes)
require_relative 'router/ping'
Expect4rRouters::Router.include(Expect4rRouters::Router::Ping)
