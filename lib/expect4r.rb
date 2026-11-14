# frozen_string_literal: true
raise LoadError, 'expect4r v2 and legacy must run in separate processes' if defined?(Expect4r::LEGACY)
require_relative 'expect4r/errors'
require_relative 'expect4r/result'
require_relative 'expect4r/patterns'
require_relative 'expect4r/diagnostics'
require_relative 'expect4r/recording'
require 'fcntl'
require_relative 'expect4r/session'
require_relative 'expect4r/wait'
require_relative 'expect4r/capture'
require_relative 'expect4r/interaction'
module Expect4r
  VERSION = '2.0.0'
  class << self
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def duration(value)
      return nil if value.nil?
      raise ArgumentError, 'duration must be a real Numeric or nil' unless value.is_a?(Numeric) && !value.is_a?(Complex)
      number = Float(value)
      raise ArgumentError, 'duration must be finite and nonnegative' unless number.finite? && number >= 0
      number
    end
    def rules(&block) = RuleSet.new(&block)
    def expect(*patterns, from:, **options, &block) = Wait.new(from, patterns, **options, &block).run
    def expect!(*patterns, from:, **options, &block) = Wait.new(from, patterns, **options, &block).run(bang: true)
    def spawn(*argv, env: {}, chdir: nil, shell: false, **settings, &block)
      options = settings_for(**settings)
      unless argv.any? && argv.all? { |s| s.is_a?(String) && !s.include?("\0") } && !argv.first.empty?
        raise ArgumentError, 'provide an executable and String argv without NUL bytes'
      end
      raise ArgumentError, 'shell must be boolean' unless shell == true || shell == false
      raise ArgumentError, 'shell mode needs one command string' if shell && argv.length != 1
      raise TypeError, 'env must be a Hash' unless env.is_a?(Hash)
      backend = Expect.spawn(*argv, env:, chdir:, shell:)
      manage(Session.new(backend, **options), &block)
    rescue Expect::SpawnError => error
      raise SpawnError.new('process could not be started', command: argv.freeze, errno: error.errno), cause: error
    end
    def open(reader, writer: reader, own: false, **settings, &block)
      options = settings_for(**settings)
      raise ArgumentError, 'own must be boolean' unless own == true || own == false
      raise TypeError, 'reader and writer must be IO objects' unless reader.is_a?(IO) && writer.is_a?(IO)
      raise IOError, 'transport is closed' if reader.closed? || writer.closed?
      readable = reader.fcntl(Fcntl::F_GETFL) & Fcntl::O_ACCMODE
      writable = writer.fcntl(Fcntl::F_GETFL) & Fcntl::O_ACCMODE
      raise IOError, 'reader is not readable' if readable == Fcntl::O_WRONLY
      raise IOError, 'writer is not writable' if writable == Fcntl::O_RDONLY
      manage(Session.new(Expect.open(reader, writer:, own:), **options), &block)
    end
    private
    def settings_for(timeout: 10, write_timeout: 10, buffer_limit: 1_048_576,
                     line_ending: "\r", logger: nil, transcript: nil, diagnostics: nil, label: nil, recording: nil, history: nil, buffer_ceiling: nil)
      timeout, write_timeout = duration(timeout), duration(write_timeout)
      unless buffer_limit.nil? || (buffer_limit.is_a?(Integer) && buffer_limit.positive?)
        raise ArgumentError, 'buffer_limit must be a positive Integer or nil'
      end
      unless buffer_ceiling.nil? || (buffer_ceiling.is_a?(Integer) && buffer_ceiling.positive? && buffer_limit && buffer_limit <= buffer_ceiling)
        raise ArgumentError, 'buffer_ceiling must be positive and cover the finite initial buffer_limit'
      end
      raise TypeError, 'line_ending must be a String' unless line_ending.is_a?(String)
      raise TypeError, 'logger must support info and debug' if logger && !(logger.respond_to?(:info) && logger.respond_to?(:debug))
      raise TypeError, 'transcript must support write' if transcript && !transcript.respond_to?(:write)
      raise TypeError, 'diagnostics must support call' if diagnostics && !diagnostics.respond_to?(:call)
      raise TypeError, 'label must be a String' unless label.nil? || label.is_a?(String)
      raise TypeError, 'recording must support write' if recording && !recording.respond_to?(:write)
      unless history.nil? || (history.is_a?(Hash) && history.keys.sort == [:max_bytes, :max_events] && history.values.all? { |v| v.is_a?(Integer) && v.positive? })
        raise ArgumentError, 'history requires positive max_events and max_bytes'
      end
      { buffer_ceiling:, recording:, history: history&.dup&.freeze, diagnostics:, label: label && String.new(label).freeze, timeout:, write_timeout:, buffer_limit:, line_ending: String.new(line_ending).b.freeze, logger:, transcript: }
    end
    def manage(session)
      return session unless block_given?
      failed = false
      begin
        yield session
      rescue Exception # Preserve interrupts and application errors while ensuring cleanup.
        failed = true
        raise
      ensure
        begin
          session.close
        rescue StandardError => error
          session.cleanup_errors << error unless session.cleanup_errors.include?(error)
          raise unless failed
        end
      end
    end
  end
end
