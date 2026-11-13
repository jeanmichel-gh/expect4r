# frozen_string_literal: true
module Expect4r
  class Session
    def interact(input: $stdin, output: $stdout, escape: "\x14", timeout: nil, raw: true)
      timeout = Expect4r.duration(timeout)
      raise TypeError, 'interaction input must be IO' unless input.is_a?(IO)
      raise TypeError, 'output must support write' unless output.respond_to?(:write)
      raise ArgumentError, 'escape must be a nonempty String' unless escape.is_a?(String) && !escape.empty?
      raise ArgumentError, 'raw must be boolean' unless raw == true || raw == false
      escape = escape.b
      operation do
        saved_mode = input.console_mode if raw && input.tty?
        started = Expect4r.monotonic
        deadline = timeout && started + timeout
        pending = ''.b
        failed = false
        begin
          input.raw! if saved_mode
          if saved_mode && @reader.tty?
            @reader.winsize = input.winsize
          end
          output_all(output, @buffer)
          @buffer.clear
          loop do
            if @eof
              return InteractionResult.new(reason: :eof, session: self, elapsed: Expect4r.monotonic - started, pending_input: ''.b.freeze)
            end
            left = deadline && deadline - Expect4r.monotonic
            if left && left <= 0
              interaction_write(pending, timeout: 0) unless pending.empty?
              return InteractionResult.new(reason: :timeout, session: self, elapsed: Expect4r.monotonic - started, pending_input: ''.b.freeze)
            end
            ready = IO.select([input, @reader], nil, nil, left)&.first || []
            if ready.include?(@reader)
              receive
              output_all(output, @buffer)
              @buffer.clear
            end
            next unless ready.include?(input)
            data = input.read_nonblock(16_384, exception: false)
            if data.nil?
              interaction_write(pending, timeout: 0) unless pending.empty?
              return InteractionResult.new(reason: :input_eof, session: self, elapsed: Expect4r.monotonic - started, pending_input: ''.b.freeze)
            end
            next if data == :wait_readable
            pending << data.b
            if (index = pending.index(escape))
              interaction_write(pending.byteslice(0, index), deadline:)
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
          begin
            input.console_mode = saved_mode if saved_mode
          rescue StandardError => error
            @cleanup_errors << error
            raise unless failed
          end
        end
      end
    end
    private
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
