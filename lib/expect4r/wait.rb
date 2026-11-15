# frozen_string_literal: true
module Expect4r
  class Wait
    attr_reader :sessions
    def initialize(sessions, patterns, timeout: 10, idle_timeout: nil, total_timeout: nil, consume: true, &block)
      @started = Expect4r.monotonic
      unless sessions.is_a?(Array) && !sessions.empty? && sessions.all? { |s| s.is_a?(Session) } && sessions.uniq.length == sessions.length
        raise ArgumentError, 'from must contain distinct Sessions'
      end
      raise ArgumentError, 'choose positional patterns or a pattern block' if block && !patterns.empty?
      raise ArgumentError, 'consume must be boolean' unless consume == true || consume == false
      @sessions = sessions.dup.freeze
      @timeout, @idle, @total = [timeout, idle_timeout, total_timeout].map { |v| Expect4r.duration(v) }
      @consume, @patterns, @counts = consume, PatternSet.new(@sessions), Hash.new(0)
      @wait_id = Diagnostics.next_id("w")
      begin
        patterns.each do |pattern|
          case pattern
          when :eof then @patterns.eof
          when :timeout then @patterns.timeout
          else @patterns.on(pattern)
          end
        end
        block.parameters.empty? ? @patterns.instance_exec(&block) : block.call(@patterns) if block
        raise ArgumentError, 'expect requires at least one pattern or event' if @patterns.rules.empty? && @patterns.events.empty?
        if !@consume && @patterns.events.keys.any? { |type, source| type == :full_buffer }
          raise ArgumentError, 'full_buffer handlers require consuming waits'
        end
        @patterns.compile!
      rescue StandardError => error
        @sessions.each do |source|
          begin
            source.diagnostic(:registration_error, registration_wait_id: @wait_id, error_class: error.class.name)
          rescue StandardError => diagnostic_error
            source.cleanup_errors << diagnostic_error
          end
        end
        raise
      end
      @tag = Object.new
    end
    def run(bang: false)
      acquired, recovery = [], {}
      begin
        @sessions.each do |source|
          source.acquire!
          acquired << source
          recovery[source] = source.buffer_recovery
          source.buffer_recovery = !!full_buffer_handler(source)
          source.diagnostic_wait_id = @wait_id
        end
        emit(:wait_start, rule_count: @patterns.rules.size, consume: @consume, timeout: @timeout, idle_timeout: @idle, total_timeout: @total)
        @patterns.rules.each_with_index do |rule, index|
          @sessions.each do |source|
            next if rule.source && !rule.source.equal?(source)
            source.diagnostic(:rule_registered, pattern_index: index, rule_name: rule.name,
                              pattern_type: rule.pattern.is_a?(String) ? :literal : :regexp, limit: rule.limit)
          end
        end
        raise BufferOverflow, 'clear failed buffer before matching again' if @sessions.any?(&:failed?)
        reset_relative(@started)
        @total_deadline = @total && @started + @total
        trace_deadlines(:initial)
        polled, continued = false, false
        loop do
          now = Expect4r.monotonic
          expiration = expired(now)
          candidate = if continued && @total_deadline && now >= @total_deadline
                        timeout_result(:total_timeout)
                      else
                        text_match || eof_result
                      end
          candidate ||= timeout_result(expiration) if expiration && (polled || @timeout != 0 || expiration != :timeout)
          candidate ||= full_buffer_result
          if candidate
            action, result, rule = candidate
            full_origin = result.session.buffer_offset if result.full_buffer?
            full_limit = result.session.buffer_limit if result.full_buffer?
            acknowledge = result.matched? || @patterns.events.key?([result.status, result.session]) || @patterns.events.key?([result.status, nil])
            if rule
              key = [rule, result.session]
              raise ResponseLimitError.new('response limit exceeded', result:) if rule.limit && @counts[key] >= rule.limit
              @counts[key] += 1
            end
            transfer_result(result, rule)
            result.session&.record_result(result)
            @current_result = result
            outcome = catch(@tag) do
              @in_action = true
              target = result.session || self
              if action
                result.session ? result.session.with_context(self) { target.instance_exec(result, &action) } : target.instance_exec(result, &action)
              end
              [:finished, result]
            ensure
              @in_action = false
            end
            if result.full_buffer?
              source = result.session
              grew = source.buffer_limit.nil? || source.buffer_limit > full_limit
              unless source.buffer_offset > full_origin || grew
                raise BufferProgressError.new('full_buffer action must consume bytes or increase capacity', result:)
              end
            end
            if outcome.first == :continue
              emit(:continuation, reset_timeout: outcome.last)
              reset_relative if outcome.last
              trace_deadlines(:continuation) if outcome.last
              continued, polled = true, false
              next
            end
            if bang && !acknowledge
              error = result.timeout? ? ExpectTimeout : UnexpectedEOF
              raise error.new("expect ended with #{result.status}", result:)
            end
            emit(:wait_result, status: result.status, reason: result.reason, selected_session_id: result.session&.session_id)
            return result
          end
          drained = false
          @sessions.each { |source| drained = source.drain_staged || drained }
          if drained
            continued = true
            next
          end
          active = @sessions.reject(&:eof?)
          ready = select_readers(active, remaining(now))
          polled = true
          ready.each do |source|
            if source.receive && source.last_receive_fresh
              received!
            end
          end
          continued = false
        end
      rescue Exception => error
        acquired.each do |source|
          begin
            source.diagnostic(:wait_error, error_class: error.class.name)
          rescue StandardError => diagnostic_error
            source.cleanup_errors << diagnostic_error
          end
        end
        raise
      ensure
        acquired.each do |source|
          source.buffer_recovery = recovery[source]
          source.diagnostic_wait_id = nil
          source.release!
        end
      end
    end
    def received!
      return unless @idle
      @idle_deadline = Expect4r.monotonic + @idle
      trace_deadlines(:receive)
    end
    def in_action? = @in_action
    def write_deadline = [@relative_deadline, @idle_deadline, @total_deadline].compact.min
    def exp_continue(reset_timeout: true)
      raise InvalidContinuation, 'continuation requires an action' unless @in_action
      raise ArgumentError, 'reset_timeout must be boolean' unless reset_timeout == true || reset_timeout == false
      if !@consume || @current_result.eof? || @current_result.reason == :total_timeout ||
         (@current_result.timeout? && (!reset_timeout || @timeout == 0 || @idle == 0))
        raise InvalidContinuation, 'continuation cannot make progress'
      end
      throw @tag, [:continue, reset_timeout]
    end
    private
    def transfer_result(result, rule)
      if rule && @consume
        result.session.consume(result.before.bytesize + result.match.bytesize)
      elsif result.eof?
        result.session.consume(result.before.bytesize)
      end
    end
    def emit(event, **fields)
      @sessions.each { |source| source.diagnostic(event, **fields) }
    end
    def trace_deadlines(cause)
      emit(:deadlines, cause:, relative_deadline: @relative_deadline,
           idle_deadline: @idle_deadline, total_deadline: @total_deadline)
    end
    def reset_relative(now = Expect4r.monotonic)
      @relative_deadline = @timeout && now + @timeout
      @idle_deadline = @idle && now + @idle
    end
    def expired(now)
      [[:total_timeout, @total_deadline], [:timeout, @relative_deadline], [:idle_timeout, @idle_deadline]].find { |_, d| d && now >= d }&.first
    end
    def remaining(now)
      deadline = write_deadline
      deadline && [deadline - now, 0].max
    end
    def select_readers(active, timeout)
      readers = active.map(&:reader)
      ready = IO.select(readers, nil, nil, timeout)&.first || []
      active.select { |s| ready.include?(s.reader) }
    rescue Errno::EINTR
      []
    end
    def text_match
      @patterns.rules.each_with_index do |rule, index|
        @sessions.each do |source|
          next if rule.source && !rule.source.equal?(source)
          buf = source.scan_buffer
          begin
            found = match(rule.pattern, buf, source.eof?)
          rescue EncodingError => error
            source.diagnostic(:rule_error, pattern_index: index, rule_name: rule.name, error_class: error.class.name)
            raise
          end
          source.diagnostic(:rule_attempt, pattern_index: index, rule_name: rule.name,
                            matched: !found.nil?, buffer_offset: source.buffer_offset, buffered_bytes: buf.bytesize) { source.diagnostic_snapshot }
          next unless found
          offset, length, captures = found
          source.diagnostic(:match, pattern_index: index, rule_name: rule.name,
                            from_offset: source.buffer_offset + offset, to_offset: source.buffer_offset + offset + length, bytes: length)
          raise EmptyMatchError, 'pattern matched zero bytes' if length.zero?
          result = Result.new(status: :matched, name: rule.name, pattern_index: index, pattern: rule.pattern,
                              session: source, before: buf.byteslice(0, offset), match: buf.byteslice(offset, length),
                              after: buf.byteslice(offset + length..), staged: staged_snapshot, captures:, elapsed: Expect4r.monotonic - @started)
          return [rule.action, result, rule]
        end
      end
      nil
    end
    def match(pattern, bytes, eof)
      if pattern.is_a?(String)
        index = bytes.index(pattern)
        return index && [index, pattern.bytesize, []]
      end
      value = bytes
      if pattern.fixed_encoding? && pattern.encoding != Encoding::BINARY
        value = bytes.dup.force_encoding(pattern.encoding)
        unless value.valid_encoding?
          valid = false
          if pattern.encoding == Encoding::UTF_8 && !eof
            1.upto([3, value.bytesize].min) do |n|
              prefix = value.byteslice(0, value.bytesize - n)
              tail = value.byteslice(value.bytesize - n, n).b.bytes
              lead = tail.first
              width = lead && (lead.between?(0xc2, 0xdf) ? 2 : lead.between?(0xe0, 0xef) ? 3 : lead.between?(0xf0, 0xf4) ? 4 : nil)
              second = tail[1]
              valid_second = second.nil? || case lead
                                           when 0xe0 then second >= 0xa0
                                           when 0xed then second <= 0x9f
                                           when 0xf0 then second >= 0x90
                                           when 0xf4 then second <= 0x8f
                                           else true
                                           end
              if prefix.valid_encoding? && width && valid_second && n < width && tail.drop(1).all? { |b| b.between?(0x80, 0xbf) }
                value, valid = prefix, true
                break
              end
            end
          end
          raise EncodingError, 'input is invalid for the pattern encoding' unless valid
        end
      end
      data = pattern.match(value)
      return nil unless data
      # MatchData offsets are character offsets for text regexes.
      [data.pre_match.bytesize, data[0].bytesize, data.captures]
    rescue ArgumentError => error
      raise EncodingError, error.message, cause: error
    end
    def staged_snapshot
      @sessions.select { |source| source.staged_bytes.positive? }.to_h { |source| [source, source.staged_buffer] }
    end
    def full_buffer_handler(source)
      @patterns.events.fetch([:full_buffer, source], @patterns.events[[:full_buffer, nil]])
    end
    def full_buffer_result
      source = @sessions.find { |item| item.buffer_full? && (full_buffer_handler(item) || item.staged_bytes.positive?) }
      return unless source
      action = full_buffer_handler(source)
      unless action
        return if source.staged_bytes.zero?
        source.staged_overflow!
      end
      source.diagnostic(:full_buffer, buffered_bytes: source.scan_buffer.bytesize, staged_bytes: source.staged_bytes)
      [action, Result.new(status: :full_buffer, session: source, before: source.buffer, staged: staged_snapshot,
                          elapsed: Expect4r.monotonic - @started), nil]
    end
    def eof_result
      source = @sessions.find(&:eof?)
      return unless source
      action = @patterns.events.fetch([:eof, source], @patterns.events[[:eof, nil]])
      [action, Result.new(status: :eof, session: source, before: source.buffer,
                          elapsed: Expect4r.monotonic - @started), nil]
    end
    def timeout_result(reason)
      @sessions.each do |source|
        source.diagnostic(:timeout, reason:, elapsed: Expect4r.monotonic - @started) { source.diagnostic_snapshot }
      end
      source = @sessions.one? ? @sessions.first : nil
      result = Result.new(status: :timeout, session: source, before: source ? source.buffer : ''.b,
                          reason:, elapsed: Expect4r.monotonic - @started, staged: staged_snapshot,
                          pending: source ? {} : @sessions.to_h { |s| [s, s.buffer] })
      [@patterns.events[[:timeout, nil]], result, nil]
    end
  end
end
