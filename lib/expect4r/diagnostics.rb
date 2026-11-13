# frozen_string_literal: true
require 'logger'
require 'thread'
module Expect4r
  # Independent streaming state per channel. Never rewrites protocol bytes.
  class Redactor
    def initialize
      @secrets, @tail = [], ''.b
    end
    def add(secret)
      raise ArgumentError, 'secret must be a nonempty String' unless secret.is_a?(String) && !secret.empty?
      @secrets << String.new(secret).b.freeze unless @secrets.include?(secret.b)
    end
    def feed(bytes, final: false)
      return bytes if @secrets.empty?
      value = @tail + bytes
      @tail = ''.b
      partial = @secrets.filter_map do |secret|
        max = [secret.bytesize - 1, value.bytesize].min
        size = max.downto(1).find { |n| secret.start_with?(value.byteslice(-n, n)) }
        value.bytesize - size if size
      end.min
      offset, output = 0, ''.b
      while offset < value.bytesize
        hit = @secrets.filter_map { |s| i = value.index(s, offset); [i, s] if i }.min_by { |i, s| [i, -s.bytesize] }
        if partial && partial >= offset && (!hit || partial <= hit.first)
          output << value.byteslice(offset, partial - offset)
          if final
            output << '[REDACTED]'
          else
            @tail = value.byteslice(partial..)
          end
          break
        elsif hit
          position, secret = hit
          output << value.byteslice(offset, position - offset) << '[REDACTED]'
          offset = position + secret.bytesize
        else
          output << value.byteslice(offset..)
          break
        end
      end
      output
    end
  end
end

module Expect4r
  # Internal metadata schema, version 1. Payload bytes and patterns are excluded.
  module Diagnostics
    @mutex = Mutex.new
    @next_id = 0
    def self.next_id(prefix)
      @mutex.synchronize { @next_id += 1; "#{prefix}#{@next_id}".freeze }
    end
  end
end

module Expect4r
  module Diagnostics
    # Human-readable sink. It never receives pattern text or unsanitized snapshots
    # once the session has registered a secret.
    class DebugOutput
      def initialize(output:, level:, bytes:, format:, preview_limit:)
        raise TypeError, 'output must support write' unless output.respond_to?(:write)
        raise ArgumentError, 'level must be :events or :matching' unless [:events, :matching].include?(level)
        raise ArgumentError, 'bytes must be boolean' unless [true, false].include?(bytes)
        raise ArgumentError, 'format must be :escaped or :hex' unless [:escaped, :hex].include?(format)
        raise ArgumentError, 'preview_limit must be a positive Integer' unless preview_limit.is_a?(Integer) && preview_limit.positive?
        @output, @level, @bytes, @format, @limit = output, level, bytes, format, preview_limit
        @failed = false
      end
      def previews? = @bytes && !@failed
      def call(event)
        return if @failed || (@level == :events && [:rule_registered, :rule_attempt].include?(event[:event]))
        line = event.map { |key, value| "#{key}=#{value.inspect}" }.join(' ')
        if @bytes && block_given?
          snapshot = yield
          if snapshot[:suppressed]
            line << ' preview=[suppressed:registered_secret]'
          else
            data = snapshot.fetch(:data)
            # A suffix makes trailing spaces, CR/LF and incomplete prompts visible.
            tail = data.byteslice(-[data.bytesize, @limit].min, @limit) || ''.b
            shown = @format == :hex ? tail.unpack1('H*').scan(/../).join(' ') : tail.b.dump
            line << " preview=#{shown} omitted_bytes=#{[data.bytesize - tail.bytesize, 0].max}"
          end
        end
        write_all(line + "\n")
      rescue StandardError
        @failed = true
        raise
      end
      private
      def write_all(bytes)
        offset = 0
        while offset < bytes.bytesize
          count = @output.write(bytes.byteslice(offset..))
          raise IOError, 'debug output made no progress' unless count.is_a?(Integer) && count.positive? && count <= bytes.bytesize - offset
          offset += count
        end
      end
    end
  end
end
