# frozen_string_literal: true
module Expect4r
  # Retention and total capture limits are independent of matching memory.
  class Capture
    attr_reader :bytes, :sink_bytes
    def initialize(sink: nil, limit: nil, retain: 65_536)
      raise TypeError, 'sink must support write' if sink && !sink.respond_to?(:write)
      { limit:, retain: }.each do |name, value|
        unless value.nil? || (value.is_a?(Integer) && value >= 0)
          raise ArgumentError, "#{name} must be a nonnegative Integer or nil"
        end
      end
      @sink, @limit, @retain = sink, limit, retain
      @bytes, @sink_bytes, @failed, @output = 0, 0, false, ''.b
    end
    def output = @output.dup.freeze
    def truncated? = @bytes > @output.bytesize
    def failed? = @failed
    def inspect = "#<Expect4r::Capture bytes=#{@bytes} sink_bytes=#{@sink_bytes} failed=#{@failed}>"
    def progress = { captured_bytes: @bytes, sink_bytes: @sink_bytes, retained_bytes: @output.bytesize }.freeze
    def append(bytes)
      raise TypeError, 'capture requires a String' unless bytes.is_a?(String)
      raise CaptureError.new('capture has failed; automatic retry is unsafe', progress:) if @failed
      if @limit && @bytes + bytes.bytesize > @limit
        @failed = true
        raise CaptureLimitError.new('capture limit exceeded', progress:, buffer: output, rejected: bytes.b.dup.freeze)
      end
      bytes = bytes.b
      return accept(bytes) unless @sink
      offset = 0
      begin
        while offset < bytes.bytesize
          count = @sink.write(bytes.byteslice(offset..))
          unless count.is_a?(Integer) && count.positive? && count <= bytes.bytesize - offset
            raise IOError, 'capture sink made invalid progress'
          end
          accept(bytes.byteslice(offset, count))
          @sink_bytes += count
          offset += count
        end
      rescue StandardError => error
        @failed = true
        raise CaptureSinkError.new('capture sink failed; inspect confirmed progress before recovery',
                                   bytes_written: offset, progress:, buffer: output,
                                   rejected: bytes.byteslice(offset..).freeze), cause: error
      end
      offset
    end
    private
    def accept(bytes)
      @bytes += bytes.bytesize
      if @retain.nil?
        @output << bytes
      elsif @retain.positive?
        if bytes.bytesize >= @retain
          @output = ''.b << bytes.byteslice(-@retain, @retain)
        else
          @output << bytes
          @output = ''.b << @output.byteslice(-@retain, @retain) if @output.bytesize > @retain
        end
      end
      bytes.bytesize
    end
  end

  CaptureResult = Data.define(:status, :output, :output_bytes, :sink_bytes, :truncated, :event) do
    def success? = status == :matched
    def inspect = "#<Expect4r::CaptureResult status=#{status} output_bytes=#{output_bytes} truncated=#{truncated}>"
    alias to_s inspect
    def pretty_print(printer) = printer.text(inspect)
  end

  # Internal wait specialization transfers data before ordinary match/EOF
  # consumption, so failed sinks cannot discard unconfirmed input.
  class CaptureWait < Wait
    def initialize(session, pattern, capture, keep, **options)
      @capture = capture
      transfer = method(:transfer_prefix)
      choose_prefix = method(:prefix_for)
      super([session], [], **options) do |rules|
        rules.on(pattern, name: :terminator)
        rules.eof
        rules.timeout
        rules.full_buffer do |event|
          prefix = choose_prefix.call(event.before, keep, pattern)
          transfer.call(self, prefix)
          exp_continue(reset_timeout: false)
        end
      end
    end
    private
    def prefix_for(bytes, keep, pattern)
      size = bytes.bytesize - keep
      if pattern.is_a?(Regexp) && pattern.fixed_encoding? && pattern.encoding != Encoding::BINARY
        size -= 1 while size.positive? && !bytes.byteslice(0, size).force_encoding(pattern.encoding).valid_encoding?
      end
      raise BufferProgressError, 'matching buffer is too small to retain context and a complete character' unless size.positive?
      bytes.byteslice(0, size)
    end
    def transfer_prefix(source, bytes, consume: true)
      begin
        @capture.append(bytes)
      rescue CaptureSinkError => error
        if error.bytes_written.positive?
          begin
            source.consume(error.bytes_written)
          rescue StandardError => secondary
            source.cleanup_errors << secondary
          end
        end
        raise
      end
      source.consume(bytes.bytesize) if consume && !bytes.empty?
    end
    def transfer_result(result, rule)
      unless result.full_buffer?
        transfer_prefix(result.session, result.before, consume: result.timeout?)
      end
      super
    end
  end

  class Session
    def capture_until(pattern, sink: nil, retain: 65_536, limit: nil, match_window: nil,
                      timeout: @timeout, idle_timeout: nil, total_timeout: nil)
      unless pattern.is_a?(String) || pattern.is_a?(Regexp)
        raise TypeError, 'capture terminator must be a String or Regexp'
      end
      raise EmptyMatchError, 'capture terminator cannot be empty' if pattern.is_a?(String) && pattern.empty?
      width = match_window.nil? ? (pattern.bytesize if pattern.is_a?(String)) : match_window
      unless width.is_a?(Integer) && width.positive?
        raise ArgumentError, 'regexp capture requires an explicit positive match_window'
      end
      if pattern.is_a?(String) && width < pattern.bytesize
        raise ArgumentError, 'match_window is smaller than the literal terminator'
      end
      capture = Capture.new(sink:, retain:, limit:)
      with_lease do
        unless @buffer_limit && width <= @buffer_limit
          raise ArgumentError, 'capture requires a finite buffer_limit covering match_window'
        end
        event = CaptureWait.new(self, pattern, capture, width - 1, timeout:, idle_timeout:, total_timeout:).run
        CaptureResult.new(status: event.status, output: capture.output, output_bytes: capture.bytes,
                          sink_bytes: capture.sink_bytes, truncated: capture.truncated?, event:)
      end
    end
    def capture_until!(pattern, **options)
      result = capture_until(pattern, **options)
      unless result.success?
        type = result.status == :timeout ? ExpectTimeout : UnexpectedEOF
        raise type.new("capture ended with #{result.status}", result:)
      end
      result
    end
  end
end
