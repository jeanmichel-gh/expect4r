# frozen_string_literal: true
require 'expect/pty'
require 'io/console'
require 'thread'
module Expect4r
  class Session
    attr_reader :timeout, :write_timeout, :buffer_limit, :line_ending, :last_result,
                :cleanup_errors, :command, :reader, :writer
    attr_accessor :trace_bytes

    def initialize(backend, timeout:, write_timeout:, buffer_limit:, line_ending:, logger:, transcript:)
      @backend, @reader, @writer = backend, backend.to_io, backend.writer
      @timeout, @write_timeout, @buffer_limit = timeout, write_timeout, buffer_limit
      @line_ending, @logger, @transcript = line_ending, logger, transcript
      @buffer, @cleanup_errors = ''.b, []
      @command = backend.command
      @mutex, @owner, @context = Mutex.new, nil, nil
      @redactor = Redactor.new
      @tx_redactor = Redactor.new
      @trace_bytes, @eof, @closed, @failed = false, false, false, false
    end
    def pid = @backend.pid
    def closed? = @closed
    def eof? = @eof
    def alive? = @backend.alive?
    def process_status = @backend.process_status
    def buffer = @buffer.dup.freeze
    def inspect = "#<Expect4r::Session pid=#{pid.inspect} closed=#{closed?} eof=#{eof?}>"
    def clear_buffer
      operation do
        previous = buffer
        @buffer, @failed = ''.b, false
        previous
      end
    end
    def redact(*secrets)
      secrets.each { |secret| @redactor.add(secret); @tx_redactor.add(secret) }
      self
    end
    def expect(*patterns, **options, &block)
      Wait.new([self], patterns, timeout: @timeout, **options, &block).run
    end
    def expect!(*patterns, **options, &block)
      Wait.new([self], patterns, timeout: @timeout, **options, &block).run(bang: true)
    end
    def exp_continue(reset_timeout: true)
      raise InvalidContinuation, 'continuation is only valid inside a wait action' unless @context && @owner == Thread.current
      @context.exp_continue(reset_timeout:)
    end
    def write(bytes, timeout: @write_timeout, sensitive: false)
      write_data(bytes, timeout:, sensitive:)
    end
    private def write_data(bytes, timeout:, sensitive:, secret: nil)
      raise TypeError, 'write requires a String' unless bytes.is_a?(String)
      timeout = Expect4r.duration(timeout)
      raise ArgumentError, 'sensitive must be boolean' unless sensitive == true || sensitive == false
      bytes = String.new(bytes).b
      operation(allow_callback: true) do
        check_open!
        redact(secret) if sensitive && secret && !secret.empty?
        redact(bytes) if sensitive && !bytes.empty?
        now = Expect4r.monotonic
        deadline = timeout && now + timeout
        budget = @context&.write_deadline
        deadline = [deadline, budget].compact.min
        offset = 0
        poll_once = timeout == 0 && (!budget || budget > now)
        while offset < bytes.bytesize
          remaining = deadline && deadline - Expect4r.monotonic
          raise WriteTimeout.new('write deadline expired', bytes_written: offset) if remaining && remaining <= 0 && !poll_once
          poll_once = false
          count = @writer.write_nonblock(bytes.byteslice(offset..), exception: false)
          if count == :wait_writable
            ready = IO.select(@eof ? [] : [@reader], [@writer], nil, remaining && [remaining, 0].max)
            raise WriteTimeout.new('write deadline expired', bytes_written: offset) unless ready
            receive if ready.first.include?(@reader)
          else
            raise TransportError.new('writer made no progress', bytes_written: offset) unless count.positive?
            offset += count
          end
        end
        trace(:write, "#{offset} bytes")
        @logger&.debug({ event: :sending, message: @tx_redactor.feed(bytes, final: true) }.freeze) if @trace_bytes
        offset
      rescue SystemCallError, IOError => error
        raise TransportError.new('write failed', bytes_written: offset || 0), cause: error
      end
    end
    def send_line(text = '', ending: @line_ending, timeout: @write_timeout, sensitive: false)
      raise TypeError, 'text and ending must be Strings' unless text.is_a?(String) && ending.is_a?(String)
      write_data(String.new(text).b + ending.b, timeout:, sensitive:, secret: text)
    end
    def wait(timeout: 5)
      raise UnsupportedOperation, 'borrowed IO has no owned child' unless @command
      timeout = Expect4r.duration(timeout)
      @backend.wait(timeout:)
    end
    def terminate(signal: :TERM)
      raise UnsupportedOperation, 'borrowed IO has no owned child' unless @command
      Process.kill(signal, pid) if alive?
      nil
    rescue Errno::ESRCH
      nil
    end
    def close(grace: 1, kill_after: 1)
      grace, kill_after = Expect4r.duration(grace), Expect4r.duration(kill_after)
      raise ArgumentError, 'cleanup deadlines must be finite' if grace.nil? || kill_after.nil?
      return process_status if @closed && !alive?
      operation do
        failure = nil
        begin
          finish_transcript
        rescue StandardError => error
          failure = error
        ensure
          begin
            @backend.soft_close(timeout: 0, term_timeout: grace)
            if @command && @backend.alive?
              begin
                Process.kill(:KILL, pid)
              rescue Errno::ESRCH
                # The child exited between status observation and the signal.
              end
              @backend.wait(timeout: kill_after)
            end
            @backend.hard_close(timeout: 0)
            @closed = true
            raise CleanupError, 'child was not reaped before cleanup deadline' if @command && @backend.alive?
          rescue StandardError => error
            @cleanup_errors << error
            failure ||= error
          end
        end
        if failure
          @cleanup_errors << failure unless @cleanup_errors.include?(failure)
          raise failure
        end
        process_status
      end
    end

    # Internal collaboration interface; no backend-private methods are called.
    def with_lease
      acquired = false
      @mutex.synchronize do
        if (@lease_owner && @lease_owner != Thread.current) || @owner
          raise BusySessionError, 'session is already in use'
        end
        unless @lease_owner
          @lease_owner = Thread.current
          acquired = true
        end
      end
      yield
    ensure
      @mutex.synchronize { @lease_owner = nil } if acquired
    end
    def acquire!
      @mutex.synchronize do
        if @lease_owner && @lease_owner != Thread.current
          raise BusySessionError, 'session is reserved by a conversation'
        end
        if @owner
          type = @owner == Thread.current ? ReentrancyError : BusySessionError
          raise type, 'session already has an active operation'
        end
        check_open!
        @owner = Thread.current
      end
    end
    def release!
      @mutex.synchronize { @owner, @context = nil, nil }
    end
    def with_context(context)
      previous, @context = @context, context
      yield
    ensure
      @context = previous
    end
    def scan_buffer = @buffer
    def failed? = @failed
    def consume(count) = @buffer.slice!(0, count)
    def record_result(result) = @last_result = result
    def receive
      data = @reader.read_nonblock(65_536, exception: false)
      return false if data == :wait_readable
      if data.nil?
        @eof = true
        finish_transcript
        return false
      end
      data = data.b
      if @buffer_limit && @buffer.bytesize + data.bytesize > @buffer_limit
        capacity = @buffer_limit - @buffer.bytesize
        @buffer << data.byteslice(0, capacity)
        @failed = true
        deliver(@redactor.feed(data))
        raise BufferOverflow.new('unmatched buffer limit exceeded', buffer: buffer,
                                 rejected: data.byteslice(capacity..).freeze)
      end
      @buffer << data
      deliver(@redactor.feed(data))
      true
    rescue Errno::EIO => error
      raise TransportError, 'non-terminal read failed' unless @reader.tty?
      @eof = true
      finish_transcript
      false
    rescue SystemCallError, IOError => error
      raise TransportError, 'read failed', cause: error
    end
    def check_open!
      raise IOError, 'session is closed' if @closed
    end

    private
    def operation(allow_callback: false)
      if allow_callback && @owner == Thread.current && @context&.in_action?
        return yield
      end
      acquire!
      begin
        yield
      ensure
        release!
      end
    end
    def trace(event, message)
      @logger&.info({ event:, message: }.freeze)
    end
    def deliver(bytes)
      return if bytes.empty?
      write_sink(@transcript, bytes) if @transcript
      @logger&.debug({ event: :receive, message: bytes }.freeze) if @trace_bytes
    end
    def finish_transcript
      deliver(@redactor.feed(''.b, final: true))
    end
    def write_sink(sink, bytes)
      offset = 0
      while offset < bytes.bytesize
        count = sink.write(bytes.byteslice(offset..))
        raise IOError, 'transcript writer made no progress' unless count.is_a?(Integer) && count.positive? && count <= bytes.bytesize - offset
        offset += count
      end
    end
  end
end
