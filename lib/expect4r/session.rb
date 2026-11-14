# frozen_string_literal: true
require 'expect/pty'
require 'io/console'
require 'thread'
module Expect4r
  class Session
    attr_reader :timeout, :write_timeout, :buffer_limit, :line_ending, :last_result,
                :cleanup_errors, :command, :reader, :writer, :write_generation, :session_id, :buffer_offset, :buffer_ceiling, :last_receive_fresh
    attr_accessor :trace_bytes, :diagnostic_wait_id, :buffer_recovery

    def initialize(backend, timeout:, write_timeout:, buffer_limit:, line_ending:, logger:, transcript:, diagnostics: nil, label: nil, recording: nil, history: nil, buffer_ceiling: nil)
      @backend, @reader, @writer = backend, backend.to_io, backend.writer
      @timeout, @write_timeout, @buffer_limit = timeout, write_timeout, buffer_limit
      @line_ending, @logger, @transcript = line_ending, logger, transcript
      @buffer, @cleanup_errors = ''.b, []
      @staged, @buffer_ceiling = ''.b, buffer_ceiling
      @buffer_recovery, @last_receive_fresh = false, false
      @write_generation = 0
      @diagnostics, @label = diagnostics, label
      @session_id = Diagnostics.next_id("s")
      @recording = recording && Diagnostics::Recording.new(recording, session_id: @session_id, label:, transport: backend.command ? :pty : :io)
      @history = history && Diagnostics::History.new(**history)
      @diagnostic_sequence, @buffer_offset, @received_bytes = 0, 0, 0
      @command = backend.command
      @mutex, @owner, @context = Mutex.new, nil, nil
      @redactor = Redactor.new
      @tx_redactor = Redactor.new
      @debug_tx_redactor = Redactor.new
      @diagnostic_has_secrets = false
      @trace_bytes, @eof, @closed, @failed = false, false, false, false
    end
    def pid = @backend.pid
    def closed? = @closed
    def eof? = @eof
    def alive? = @backend.alive?
    def process_status = @backend.process_status
    def diagnostic_history = @history ? @history.snapshot : [].freeze
    def diagnostic_history_dropped = @history ? @history.dropped_events : 0
    def diagnostic_history_bytes = @history ? @history.retained_bytes : 0
    def recording_failed? = !!@recording&.failed
    def buffer = @buffer.dup.freeze
    def inspect = "#<Expect4r::Session pid=#{pid.inspect} closed=#{closed?} eof=#{eof?}>"
    def staged_buffer = @staged.dup.freeze
    def staged_overflow!
      @failed = true
      raise BufferOverflow.new('staged input exceeds matching capacity', buffer: buffer, rejected: staged_buffer)
    end
    def staged_bytes = @staged.bytesize
    def buffer_full? = @buffer_limit && @buffer.bytesize >= @buffer_limit
    def consume_buffer(count)
      unless count.is_a?(Integer) && count.positive?
        raise ArgumentError, 'count must be a positive Integer'
      end
      operation(allow_callback: true) do
        raise ArgumentError, 'count exceeds matching buffer' if count > @buffer.bytesize
        consume(count).freeze
      end
    end
    def resize_buffer(limit)
      unless limit.nil? || (limit.is_a?(Integer) && limit.positive?)
        raise ArgumentError, 'buffer limit must be a positive Integer or nil'
      end
      operation(allow_callback: true) do
        raise ArgumentError, 'buffer limit exceeds ceiling' if @buffer_ceiling && (limit.nil? || limit > @buffer_ceiling)
        raise ArgumentError, 'buffer limit is below retained bytes' if limit && limit < @buffer.bytesize
        previous, @buffer_limit = @buffer_limit, limit
        diagnostic(:buffer_resize, previous_limit: previous, limit:)
        self
      end
    end
    def drain_staged
      return false if @staged.empty?
      count = @buffer_limit ? [@buffer_limit - @buffer.bytesize, @staged.bytesize].min : @staged.bytesize
      return false unless count.positive?
      @buffer << @staged.byteslice(0, count)
      @staged = @staged.byteslice(count..)
      diagnostic(:stage_drain, bytes: count, buffered_bytes: @buffer.bytesize, staged_bytes: @staged.bytesize)
      true
    end
    def clear_buffer
      operation do
        previous = (@buffer + @staged).freeze
        consume(@buffer.bytesize)
        @buffer_offset = @received_bytes
        @buffer, @staged, @failed = ''.b, ''.b, false
        diagnostic(:buffer_clear, removed_bytes: previous.bytesize)
        previous
      end
    end
    def with_debug(level: :matching, output: $stderr, bytes: false, format: :escaped, preview_limit: 256)
      raise ArgumentError, 'with_debug requires a block' unless block_given?
      sink = Diagnostics::DebugOutput.new(output:, level:, bytes:, format:, preview_limit:)
      with_lease do
        previous, @debug_output = @debug_output, sink
        begin
          yield self
        ensure
          @debug_output = previous
        end
      end
    end
    def redact(*secrets)
      secrets.each do |secret|
        @redactor.add(secret)
        @tx_redactor.add(secret)
        @debug_tx_redactor.add(secret)
        @recording&.redact(secret)
        @diagnostic_has_secrets = true
      end
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
        diagnostic(:write_start, requested_bytes: bytes.bytesize)
        poll_once = timeout == 0 && (!budget || budget > now)
        while offset < bytes.bytesize
          remaining = deadline && deadline - Expect4r.monotonic
          raise write_timeout_error(offset) if remaining && remaining <= 0 && !poll_once
          poll_once = false
          count = @writer.write_nonblock(bytes.byteslice(offset..), exception: false)
          if count == :wait_writable
            ready = IO.select(@eof ? [] : [@reader], [@writer], nil, remaining && [remaining, 0].max)
            raise write_timeout_error(offset) unless ready
            receive if ready.first.include?(@reader)
          else
            raise TransportError.new('writer made no progress', bytes_written: offset) unless count.positive?
            safe_log = @tx_redactor.feed(bytes.byteslice(offset, count)) if @trace_bytes || @diagnostic_has_secrets
            safe_bytes = @debug_tx_redactor.feed(bytes.byteslice(offset, count)) if @debug_output&.previews? || @diagnostic_has_secrets
            offset += count
            @write_generation += 1
            @recording&.io(:tx, bytes.byteslice(offset - count, count))
            diagnostic(:write_progress, bytes: count, confirmed_bytes: offset, requested_bytes: bytes.bytesize)
            debug_bytes(:tx, safe_bytes)
            @logger&.debug({ event: :sending, message: safe_log }.freeze) if @trace_bytes && safe_log && !safe_log.empty?
          end
        end
        trace(:write, "#{offset} bytes")
        offset
      rescue ReplayMismatchError => error
        raise ReplayMismatchError.new(error.message, bytes_written: offset || 0, progress: error.progress), cause: error
      rescue WriteTimeout => error
        if error.progress && error.progress[:replay]
          raise WriteTimeout.new('recorded write timeout', bytes_written: offset || 0, progress: error.progress), cause: error
        end
        raise
      rescue SystemCallError, IOError => error
        diagnostic_during_failure(:write_error, error_class: error.class.name, confirmed_bytes: offset || 0)
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
          safe_log = @tx_redactor.feed(''.b, final: true)
          @logger&.debug({ event: :sending, message: safe_log }.freeze) if @trace_bytes && !safe_log.empty?
          @backend.verify_replay! if @backend.respond_to?(:verify_replay!)
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
        begin
          @recording&.finish(complete: failure.nil?)
        rescue StandardError => error
          @cleanup_errors << error
          failure ||= error
        end
        if failure
          @cleanup_errors << failure unless @cleanup_errors.include?(failure)
          diagnostic_during_failure(:cleanup_error, error_class: failure.class.name)
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
    def consume(count)
      previous = @buffer_offset
      removed = @buffer.slice!(0, count)
      @buffer_offset += removed.bytesize
      diagnostic(:consume, from_offset: previous, to_offset: @buffer_offset, bytes: removed.bytesize, buffered_bytes: @buffer.bytesize)
      removed
    end
    def diagnostic(event, **fields, &preview)
      return unless @diagnostics || @debug_output || @history || @recording
      @diagnostic_sequence += 1
      record = fields.merge(schema_version: 1, event:, session_id: @session_id,
                                    label: @label, wait_id: @diagnostic_wait_id,
                                    sequence: @diagnostic_sequence, monotonic: Expect4r.monotonic).freeze
      @history&.add(record)
      @recording&.event(record)
      begin
        @diagnostics&.call(record)
      rescue StandardError
        @diagnostics = nil
        raise
      end
      @debug_output&.call(record, &preview)
    end
    def diagnostic_snapshot
      @diagnostic_has_secrets ? { suppressed: true } : { data: @buffer }
    end
    def record_result(result) = @last_result = result
    def receive
      @last_receive_fresh = false
      return drain_staged unless @staged.empty?
      data = @reader.read_nonblock(65_536, exception: false)
      return false if data == :wait_readable
      if data.nil?
        @eof = true
        diagnostic(:eof, stream_offset: @received_bytes, buffered_bytes: @buffer.bytesize)
        finish_transcript
        return false
      end
      data = data.b
      read_offset = @received_bytes
      @received_bytes += data.bytesize
      @last_receive_fresh = true
      # Deadline notifications can invoke user diagnostics during backpressure.
      # Retain bytes and advance redaction before calling those fallible hooks.
      if @buffer_recovery
        @staged = data
        safe = @redactor.feed(data)
        @context.received! if @context.respond_to?(:received!)
        @recording&.io(:rx, data)
        drain_staged
        diagnostic(:receive, bytes: data.bytesize, stream_offset: read_offset, buffered_bytes: @buffer.bytesize, staged_bytes: @staged.bytesize)
        deliver(safe)
        return true
      end
      if @buffer_limit && @buffer.bytesize + data.bytesize > @buffer_limit
        capacity = @buffer_limit - @buffer.bytesize
        @buffer << data.byteslice(0, capacity)
        @failed = true
        error = BufferOverflow.new('unmatched buffer limit exceeded', buffer: buffer,
                                   rejected: data.byteslice(capacity..).freeze)
        safe = @redactor.feed(data)
        begin
          @context.received! if @context.respond_to?(:received!)
        rescue StandardError => diagnostic_error
          @cleanup_errors << diagnostic_error
        end
        begin
          @recording&.io(:rx, data)
        rescue StandardError => recording_error
          @cleanup_errors << recording_error
        end
        diagnostic_during_failure(:receive, bytes: data.bytesize, stream_offset: read_offset, buffered_bytes: @buffer.bytesize)
        diagnostic_during_failure(:overflow, limit: @buffer_limit, buffered_bytes: @buffer.bytesize, rejected_bytes: data.bytesize - capacity)
        begin
          deliver(safe)
        rescue StandardError => delivery_error
          @cleanup_errors << delivery_error
        end
        raise error
      end
      @buffer << data
      safe = @redactor.feed(data)
      @context.received! if @context.respond_to?(:received!)
      @recording&.io(:rx, data)
      diagnostic(:receive, bytes: data.bytesize, stream_offset: read_offset, buffered_bytes: @buffer.bytesize)
      deliver(safe)
      true
    rescue Errno::EIO => error
      raise TransportError, 'non-terminal read failed' unless @reader.tty?
      @eof = true
      diagnostic(:eof, stream_offset: @received_bytes, buffered_bytes: @buffer.bytesize)
      finish_transcript
      false
    rescue SystemCallError, IOError => error
      diagnostic_during_failure(:read_error, error_class: error.class.name)
      raise TransportError, 'read failed', cause: error
    end
    def check_open!
      raise IOError, 'session is closed' if @closed
    end

    private
    def diagnostic_during_failure(event, **fields)
      diagnostic(event, **fields)
    rescue StandardError => error
      @cleanup_errors << error
    end
    def write_timeout_error(offset)
      diagnostic_during_failure(:write_timeout, confirmed_bytes: offset)
      WriteTimeout.new('write deadline expired', bytes_written: offset)
    end
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
    def debug_bytes(direction, bytes)
      return unless @debug_output&.previews? && bytes && !bytes.empty?
      diagnostic(:byte_preview, direction:, sanitized_bytes: bytes.bytesize) { { data: bytes } }
    end
    def deliver(bytes)
      return if bytes.empty?
      debug_bytes(:rx, bytes)
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
