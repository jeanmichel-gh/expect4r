# frozen_string_literal: true
module Expect4r
  class Session
    def interact(input: $stdin, output: $stdout, escape: "\x14", escape_key: nil, timeout: nil, raw: true)
      escape = interaction_control_key(escape_key) unless escape_key.nil?
      timeout = Expect4r.duration(timeout)
      raise TypeError, 'interaction input must be IO' unless input.is_a?(IO)
      raise TypeError, 'output must support write' unless output.respond_to?(:write)
      raise ArgumentError, 'escape must be a nonempty String' unless escape.is_a?(String) && !escape.empty?
      raise ArgumentError, 'raw must be boolean' unless raw == true || raw == false
      escape = escape.b
      operation do
        previous_recovery = @buffer_recovery
        saved_mode = input.console_mode if raw && input.tty?
        started = Expect4r.monotonic
        deadline = timeout && started + timeout
        pending = ''.b
        failed = false
        interaction_reason = :error
        begin
          @buffer_recovery = true
          diagnostic(:interaction_start, raw:, timeout:)
          input.raw! if saved_mode
          if saved_mode && @reader.tty?
            @reader.winsize = input.winsize
          end
          output_all(output, @buffer)
          consume(@buffer.bytesize)
          loop do
            if @eof
              interaction_reason = :eof
              return InteractionResult.new(reason: :eof, session: self, elapsed: Expect4r.monotonic - started, pending_input: ''.b.freeze)
            end
            left = deadline && deadline - Expect4r.monotonic
            if left && left <= 0
              interaction_write(pending, timeout: 0) unless pending.empty?
              interaction_reason = :timeout
              return InteractionResult.new(reason: :timeout, session: self, elapsed: Expect4r.monotonic - started, pending_input: ''.b.freeze)
            end
            if drain_staged
              output_all(output, @buffer)
              consume(@buffer.bytesize)
              next
            end
            ready = IO.select([input, @reader], nil, nil, left)&.first || []
            if ready.include?(@reader)
              receive
              output_all(output, @buffer)
              consume(@buffer.bytesize)
            end
            next unless ready.include?(input)
            data = input.read_nonblock(16_384, exception: false)
            if data.nil?
              interaction_write(pending, timeout: 0) unless pending.empty?
              interaction_reason = :input_eof
              return InteractionResult.new(reason: :input_eof, session: self, elapsed: Expect4r.monotonic - started, pending_input: ''.b.freeze)
            end
            next if data == :wait_readable
            pending << data.b
            if (index = pending.index(escape))
              interaction_write(pending.byteslice(0, index), deadline:)
              interaction_reason = :escape
              return InteractionResult.new(reason: :escape, session: self, elapsed: Expect4r.monotonic - started,
                                           pending_input: pending.byteslice(index + escape.bytesize..).freeze)
            end
            hold = [escape.bytesize - 1, pending.bytesize].min
            hold -= 1 while hold.positive? && !escape.start_with?(pending.byteslice(-hold, hold))
            send_size = pending.bytesize - hold
            interaction_write(pending.slice!(0, send_size), deadline:) if send_size.positive?
          end
        rescue Exception # Restore terminal modes for interrupts as well as errors.
          failed = true
          raise
        ensure
          @buffer_recovery = previous_recovery
          begin
            input.console_mode = saved_mode if saved_mode
          rescue StandardError => error
            @cleanup_errors << error
            raise unless failed
          ensure
            begin
              diagnostic(:interaction_end, reason: interaction_reason, elapsed: Expect4r.monotonic - started)
            rescue StandardError => error
              @cleanup_errors << error
              raise unless failed
            end
          end
        end
      end
    end
    private
    def interaction_control_key(key)
      unless key.is_a?(String) && key.ascii_only? && key.bytesize == 3 &&
             key.upcase.start_with?('C-') && (63..95).cover?(key.upcase.getbyte(2))
        raise ArgumentError, 'escape_key must be C-A through C-Z, C-@, C-[, C-\\, C-], C-^, C-_ or C-?'
      end
      value = key.upcase.getbyte(2)
      (value == 63 ? 127 : value & 31).chr(Encoding::BINARY)
    end
    # The interaction owns the session. Writes borrow that ownership, never reads.
    def interaction_write(bytes, deadline: nil, timeout: @write_timeout)
      context = Struct.new(:in_action?, :write_deadline).new(true, deadline)
      with_context(context) { write(bytes, timeout:) }
    end
    def output_all(output, bytes)
      offset = 0
      while offset < bytes.bytesize
        count = output.write(bytes.byteslice(offset..))
        raise IOError, 'interactive output made no progress' unless count.is_a?(Integer) && count.positive? && count <= bytes.bytesize - offset
        offset += count
      end
    end
  end
end
