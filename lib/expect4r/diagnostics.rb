# frozen_string_literal: true
require 'logger'
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
