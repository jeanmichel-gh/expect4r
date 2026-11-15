# frozen_string_literal: true
require 'json'
require 'time'
module Expect4r
  module Diagnostics
    class History
      attr_reader :dropped_events, :retained_bytes
      def initialize(max_events:, max_bytes:)
        @max_events, @max_bytes = max_events, max_bytes
        @entries, @sizes = [], []
        @dropped_events, @retained_bytes = 0, 0
      end
      def add(event)
        size = JSON.generate(event).bytesize
        @entries << event
        @sizes << size
        @retained_bytes += size
        while @entries.size > @max_events || @retained_bytes > @max_bytes
          @entries.shift
          @retained_bytes -= @sizes.shift
          @dropped_events += 1
        end
      end
      def snapshot = @entries.dup.freeze
    end

    # IO observations retain their original timestamps and byte ranges. Payload
    # segments may arrive later because a trailing secret prefix is held back.
    class Recording
      attr_reader :failed
      def initialize(output, session_id:, label:, transport: :io)
        @output, @session_id, @label, @transport = output, session_id, label, transport
        @origin, @wall = Expect4r.monotonic, Time.now.utc.iso8601(6)
        @sequence, @started, @finished, @failed = 0, false, false, false
        @secrets = []
        @pending = { rx: ''.b, tx: ''.b }
        @marked = { rx: [], tx: [] }
        @observed, @emitted = { rx: 0, tx: 0 }, { rx: 0, tx: 0 }
      end
      def redact(secret)
        raise ArgumentError, 'secret must be a nonempty String' unless secret.is_a?(String) && !secret.empty?
        @secrets << secret.b.dup.freeze unless @secrets.include?(secret.b)
      end
      def event(metadata)
        emit(:event, metadata:)
      end
      def io(direction, bytes)
        offset = @observed.fetch(direction)
        @observed[direction] += bytes.bytesize
        emit(:io, direction:, stream_offset: offset, bytes: bytes.bytesize)
        @pending[direction] << bytes
        payload(direction)
      end
      def finish(complete:)
        return if @finished || @failed
        [:rx, :tx].each { |direction| payload(direction, final: true) }
        emit(:end, complete:, observed_bytes: @observed.dup)
        @finished = true
      end
      private
      def payload(direction, final: false)
        value = @pending.fetch(direction)
        return if value.empty?
        spans, partial = @marked.fetch(direction).dup, []
        @secrets.each do |secret|
          at = 0
          while (hit = value.index(secret, at))
            spans << [hit, hit + secret.bytesize]
            at = hit + 1
          end
          1.upto([secret.bytesize - 1, value.bytesize].min) do |size|
            partial << value.bytesize - size if secret.start_with?(value.byteslice(-size, size))
          end
        end
        cut = final ? value.bytesize : (partial.min || value.bytesize)
        if final
          partial.each { |start| spans << [start, value.bytesize] }
        end
        return if cut.zero?
        merged = []
        spans.select { |start, stop| start < cut }.map { |start, stop| [start, [stop, cut].min] }.sort.each do |start, stop|
          if merged.any? && start <= merged.last[1]
            merged.last[1] = [merged.last[1], stop].max
          else
            merged << [start, stop]
          end
        end
        safe = value.byteslice(0, cut).dup
        merged.each { |start, stop| safe[start, stop - start] = "\0" * (stop - start) }
        origin = @emitted.fetch(direction)
        emit(:payload, direction:, stream_offset: origin, bytes: cut,
             encoding: 'base64', data: [safe].pack('m0'),
             redactions: merged.map { |start, stop| { stream_offset: origin + start, bytes: stop - start } })
        @marked[direction] = spans.select { |start, stop| stop > cut }.map { |start, stop| [[start - cut, 0].max, stop - cut] }
        @emitted[direction] += cut
        @pending[direction] = value.byteslice(cut..)
      end
      def emit(type, **fields)
        return if @failed || @finished
        unless @started
          @started = true
          write(type: :header, format: 'expect4r-dialogue', version: 1, session_id: @session_id,
                label: @label, wall_clock_origin: @wall, monotonic_origin: @origin,
                ruby_version: RUBY_VERSION, platform: RUBY_PLATFORM,
                expect4r_version: Expect4r::VERSION, transport: @transport)
        end
        @sequence += 1
        write(fields.merge(type:, sequence: @sequence, elapsed: Expect4r.monotonic - @origin))
      rescue StandardError
        @failed = true
        raise
      end
      def write(record)
        bytes = JSON.generate(record) + "\n"
        offset = 0
        while offset < bytes.bytesize
          count = @output.write(bytes.byteslice(offset..))
          raise IOError, 'recording output made no progress' unless count.is_a?(Integer) && count.positive? && count <= bytes.bytesize - offset
          offset += count
        end
      end
    end
  end
end
