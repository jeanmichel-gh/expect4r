# frozen_string_literal: true
module Expect4r
  # Strict reader of the versioned recording format. Metadata never executes code.
  class ReplayTrace
    attr_reader :header, :redactions
    def self.load(source)
      text = source.respond_to?(:read) ? source.read : File.binread(source)
      new(text)
    end
    def initialize(text)
      invalid!('recording must end with a newline') unless text.is_a?(String) && text.end_with?("\n")
      rows = text.lines.map { |line| JSON.parse(line) }
      @header = rows.shift
      invalid!('unsupported recording header') unless @header.is_a?(Hash) && @header['type'] == 'header' &&
        @header['format'] == 'expect4r-dialogue' && @header['version'] == 1 && @header['session_id'].is_a?(String)
      invalid!('recording is incomplete') unless rows.last.is_a?(Hash) && rows.last['type'] == 'end' && rows.last['complete'] == true
      @streams = { rx: ''.b, tx: ''.b }
      @observed = { rx: 0, tx: 0 }
      @redactions, @steps = [], []
      elapsed, eof_seen = 0, false
      rows.each_with_index do |row, index|
        invalid!('invalid record sequence') unless row.is_a?(Hash) && row['sequence'].is_a?(Integer) && row['sequence'] == index + 1
        time = row['elapsed']
        invalid!('invalid elapsed timestamp') unless time.is_a?(Numeric) && time.finite? && time >= elapsed
        elapsed = time
        case row['type']
        when 'io'
          direction, start, size = range(row)
          invalid!('noncontiguous IO observations') unless start == @observed[direction]
          invalid!('RX after EOF') if direction == :rx && eof_seen
          @observed[direction] += size
          @steps << { kind: direction, stream_offset: start, bytes: size, elapsed: time }
        when 'payload'
          direction, start, size = range(row)
          invalid!('noncontiguous payloads') unless start == @streams[direction].bytesize
          invalid!('unsupported payload encoding') unless row['encoding'] == 'base64' && row['data'].is_a?(String)
          data = row['data'].unpack1('m0')
          invalid!('payload size mismatch') unless data.bytesize == size
          invalid!('payload precedes its IO observation') if start + size > @observed[direction]
          spans = row['redactions']
          invalid!('invalid redaction list') unless spans.is_a?(Array)
          previous = start
          spans.each do |span|
            invalid!('invalid redaction') unless span.is_a?(Hash)
            at, length = span.values_at('stream_offset', 'bytes')
            invalid!('invalid redaction range') unless at.is_a?(Integer) && length.is_a?(Integer) && length.positive? && at >= previous && at + length <= start + size
            invalid!('redaction is not masked') unless data.byteslice(at - start, length) == "\0" * length
            @redactions << { direction:, stream_offset: at, bytes: length }.freeze
            previous = at + length
          end
          @streams[direction] << data
        when 'event'
          metadata = row['metadata']
          invalid!('invalid event metadata') unless metadata.is_a?(Hash) && metadata['session_id'] == @header['session_id']
          event = metadata['event']
          if event == 'eof'
            invalid!('duplicate EOF') if eof_seen
            eof_seen = true
            @steps << { kind: :eof, elapsed: time }
          elsif ['read_error', 'write_error', 'write_timeout'].include?(event)
            invalid!('invalid recorded error class') unless event == 'write_timeout' || metadata['error_class'].is_a?(String)
            @steps << { kind: event.to_sym, elapsed: time, recorded_class: metadata['error_class'] }
          end
        when 'end'
          invalid!('end must be the last record') unless index == rows.size - 1
          counts = row['observed_bytes']
          invalid!('invalid end byte counts') unless counts.is_a?(Hash) && counts.values.all? { |value| value.is_a?(Integer) && value >= 0 } && counts == @observed.transform_keys(&:to_s)
        else
          invalid!('unknown recording record type')
        end
      end
      invalid!('payload and observation totals differ') unless @streams.all? { |direction, bytes| bytes.bytesize == @observed[direction] }
      @streams.each_value(&:freeze)
      @streams.freeze
      @steps.each { |step| deep_freeze(step) }.freeze
      @redactions.freeze
      deep_freeze(@header)
      @observed.freeze
      freeze
    rescue JSON::ParserError, ArgumentError => error
      raise ReplayFormatError, "invalid recording: #{error.class.name}"
    end
    def summary = { version: 1, observed_bytes: @observed, redactions: @redactions, steps: @steps.size }.freeze
    def inspect = "#<Expect4r::ReplayTrace steps=#{@steps.size} redactions=#{@redactions.size}>"
    def actions(substitutions: {})
      raise ArgumentError, 'substitutions must be a Hash' unless substitutions.is_a?(Hash)
      expected = @redactions.map { |span| [span[:direction], span[:stream_offset]] }
      unless (expected - substitutions.keys).empty? && (substitutions.keys - expected).empty?
        raise ReplayFormatError, 'provide exactly one substitution for every redaction span'
      end
      streams = @streams.transform_values(&:dup)
      @redactions.each do |span|
        replacement = substitutions.fetch([span[:direction], span[:stream_offset]])
        unless replacement.is_a?(String) && replacement.bytesize == span[:bytes]
          raise ReplayFormatError, 'redaction substitutions must preserve byte length'
        end
        streams[span[:direction]][span[:stream_offset], span[:bytes]] = replacement.b
      end
      @steps.map do |step|
        if [:rx, :tx].include?(step[:kind])
          step.merge(data: streams[step[:kind]].byteslice(step[:stream_offset], step[:bytes]).freeze).freeze
        else
          step
        end
      end.freeze
    end
    private
    def invalid!(message) = raise(ReplayFormatError, message)
    def range(row)
      direction = { 'rx' => :rx, 'tx' => :tx }[row['direction']]
      start, size = row.values_at('stream_offset', 'bytes')
      invalid!('invalid IO range') unless direction && start.is_a?(Integer) && start >= 0 && size.is_a?(Integer) && size.positive?
      [direction, start, size]
    end
    def deep_freeze(value)
      case value
      when Hash then value.each { |key, item| key.freeze; deep_freeze(item) }
      when Array then value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end
  end

  class ReplayTransportFailure < IOError
    attr_reader :recorded_class
    def initialize(recorded_class)
      @recorded_class = recorded_class
      super('recorded transport failure')
    end
  end

  # Real selectable pipe endpoints; replay itself performs no external IO.
  class ReplayBackend
    attr_reader :writer
    def initialize(actions, fragment_size:, timing:, speed:, require_all_reads:)
      @actions, @fragment_size, @timing, @speed = actions, fragment_size, timing, speed
      @require_all_reads = require_all_reads
      @index, @within, @tx_offset = 0, 0, 0
      @incoming = []
      @closed, @notified, @read_eof = false, false, false
      @started, @mutex, @condition = Expect4r.monotonic, Mutex.new, ConditionVariable.new
      @reader, @writer = IO.pipe
      @raw_read, @notify = @reader.method(:read_nonblock), @writer.method(:write_nonblock)
      backend = self
      @reader.define_singleton_method(:read_nonblock) { |size, exception: true| backend.read(size, exception:) }
      @writer.define_singleton_method(:write_nonblock) { |bytes, exception: true| backend.write(bytes) }
      @mutex.synchronize { refresh }
      @worker = Thread.new do
        Thread.current.name = 'expect4r-replay'
        schedule
      end if timing == :scaled
    rescue StandardError
      @reader.close if @reader && !@reader.closed?
      @writer.close if @writer && !@writer.closed?
      raise
    end
    def to_io = @reader
    def command = nil
    def pid = nil
    def alive? = false
    def process_status = nil
    def soft_close(**options) = nil
    def hard_close(**options)
      @mutex.synchronize { @closed = true; @condition.broadcast }
      if @worker && !@worker.join(1)
        raise CleanupError, 'replay timer did not stop'
      end
    ensure
      @reader.close unless @reader.closed?
      @writer.close unless @writer.closed?
    end
    def read(size, exception:)
      @mutex.synchronize do
        raise @failure if @failure
        return nil if @read_eof
        refresh
        step = @incoming.first
        unless step
          return :wait_readable unless exception
          raise IO::EAGAINWaitReadable
        end
        case step[:kind]
        when :eof
          @read_eof = true
          @incoming.shift
          refresh
          nil
        when :read_error
          @incoming.shift
          refresh
          raise ReplayTransportFailure, step[:recorded_class]
        when :rx
          width = [size, @fragment_size || size, step[:data].bytesize - step[:within]].min
          bytes = step[:data].byteslice(step[:within], width)
          step[:within] += width
          @incoming.shift if step[:within] == step[:data].bytesize
          refresh
          bytes
        else
          return :wait_readable unless exception
          raise IO::EAGAINWaitReadable
        end
      end
    end
    def write(bytes)
      @mutex.synchronize do
        raise @failure if @failure
        return 0 if bytes.empty?
        step = @actions[@index]
        if step && [:write_error, :write_timeout].include?(step[:kind])
          advance
          if step[:kind] == :write_timeout
            raise WriteTimeout.new('recorded write timeout', progress: { replay: true }.freeze)
          end
          raise ReplayTransportFailure, step[:recorded_class]
        end
        unless step && step[:kind] == :tx
          mismatch!('unexpected TX before pending RX/event or after recorded TX', @tx_offset)
        end
        # Accept a prefix up to the next RX/error barrier; adjacent recorded write
        # boundaries do not constrain the caller's write-call boundaries.
        expected, index, offset = ''.b, @index, @within
        while (part = @actions[index]) && part[:kind] == :tx && expected.bytesize < bytes.bytesize
          expected << part[:data].byteslice(offset, bytes.bytesize - expected.bytesize)
          index += 1
          offset = 0
        end
        count = [expected.bytesize, bytes.bytesize].min
        differing = (0...count).find { |i| expected.getbyte(i) != bytes.getbyte(i) }
        mismatch!('TX mismatch', @tx_offset + differing) if differing
        remaining = count
        while remaining.positive?
          available = @actions[@index][:data].bytesize - @within
          taken = [remaining, available].min
          @within += taken
          @tx_offset += taken
          remaining -= taken
          @within == @actions[@index][:data].bytesize ? advance : refresh
        end
        count
      end
    end
    def verify_replay!(require_all_reads: @require_all_reads)
      @mutex.synchronize do
        raise @failure if @failure
        refresh
        pending = @actions.drop(@index) + @incoming
        if pending.any? { |step| [:tx, :read_error, :write_error, :write_timeout].include?(step[:kind]) }
          raise ReplayIncompleteError, 'recorded outgoing bytes or transport failures remain unexercised'
        end
        if require_all_reads && !pending.empty?
          raise ReplayIncompleteError, 'recorded input or EOF remains unread'
        end
        true
      end
    end
    private
    def ready?(step)
      return false unless step && [:rx, :eof, :read_error].include?(step[:kind])
      @timing == :immediate || Expect4r.monotonic >= @started + step[:elapsed] / @speed
    end
    def refresh
      while ready?(@actions[@index])
        @incoming << @actions[@index].merge(within: 0)
        @index += 1
        @within = 0
      end
      wanted = @failure || @read_eof || !@incoming.empty?
      if wanted && !@notified
        @notify.call("\1", exception: false)
        @notified = true
      elsif !wanted && @notified
        @raw_read.call(1, exception: false)
        @notified = false
      end
      @condition.broadcast
    end
    def advance
      @index += 1
      @within = 0
      refresh
    end
    def mismatch!(message, offset)
      @failure = ReplayMismatchError.new("#{message} at TX byte offset #{offset}", progress: { direction: :tx, stream_offset: offset }.freeze)
      refresh
      raise @failure
    end
    def schedule
      @mutex.synchronize do
        until @closed
          refresh
          step = @actions[@index]
          if step && [:rx, :eof, :read_error].include?(step[:kind]) && !ready?(step)
            @condition.wait(@mutex, [[@started + step[:elapsed] / @speed - Expect4r.monotonic, 0].max, 60].min)
          else
            @condition.wait(@mutex)
          end
        end
      end
    end
  end

  class Session
    def verify_replay!(require_all_reads: nil)
      raise UnsupportedOperation, 'session is not a replay' unless @backend.respond_to?(:verify_replay!)
      unless require_all_reads.nil? || [true, false].include?(require_all_reads)
        raise ArgumentError, 'require_all_reads must be boolean'
      end
      operation do
        require_all_reads.nil? ? @backend.verify_replay! : @backend.verify_replay!(require_all_reads:)
      end
    end
  end

  class << self
    def replay(source, substitutions: {}, fragment_size: nil, timing: :immediate, speed: 1,
               require_all_reads: false, **settings, &block)
      options = settings_for(**settings)
      unless fragment_size.nil? || (fragment_size.is_a?(Integer) && fragment_size.positive?)
        raise ArgumentError, 'fragment_size must be positive or nil'
      end
      raise ArgumentError, 'timing must be :immediate or :scaled' unless [:immediate, :scaled].include?(timing)
      speed = duration(speed)
      raise ArgumentError, 'speed must be finite and positive' unless speed && speed.positive?
      raise ArgumentError, 'require_all_reads must be boolean' unless [true, false].include?(require_all_reads)
      trace = source.is_a?(ReplayTrace) ? source : ReplayTrace.load(source)
      backend = ReplayBackend.new(trace.actions(substitutions:), fragment_size:, timing:, speed:, require_all_reads:)
      begin
        session = Session.new(backend, **options)
        session.redact(*substitutions.values.uniq) unless substitutions.empty?
      rescue Exception => error
        begin
          backend.hard_close
        rescue StandardError => cleanup
          raise error, cause: cleanup
        end
        raise
      end
      manage(session, &block)
    end
  end
end
