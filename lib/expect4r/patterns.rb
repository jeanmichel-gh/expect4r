# frozen_string_literal: true
module Expect4r
  Rule = Data.define(:pattern, :name, :action, :limit, :source)
  class PatternSet
    attr_reader :rules, :events
    def initialize(sources = nil)
      @sources, @rules, @events = sources, [], {}
    end
    def on(pattern, name: nil, limit: nil, from: nil, &action)
      unless pattern.is_a?(String) || pattern.is_a?(Regexp)
        raise TypeError, 'pattern must be a String or Regexp'
      end
      raise EmptyMatchError, 'literal pattern cannot be empty' if pattern.is_a?(String) && pattern.empty?
      raise ArgumentError, 'name must be a Symbol' unless name.nil? || name.is_a?(Symbol)
      raise ArgumentError, "duplicate pattern name #{name}" if name && @rules.any? { |r| r.name == name }
      raise ArgumentError, 'limit must be positive' unless limit.nil? || (limit.is_a?(Integer) && limit.positive?)
      validate_source(from)
      pattern = pattern.is_a?(String) ? String.new(pattern).b.freeze : pattern.dup.freeze
      @rules << Rule.new(pattern:, name:, action:, limit:, source: from)
      self
    end
    def timeout(&action) = event(:timeout, nil, action)
    def full_buffer(from: nil, &action)
      raise ArgumentError, 'full_buffer requires an action' unless action
      event(:full_buffer, from, action)
    end
    def eof(from: nil, &action) = event(:eof, from, action)
    def use(rules)
      raise TypeError, 'expected a RuleSet' unless rules.is_a?(RuleSet)
      rules.rules.each { |r| on(r.pattern, name: r.name, limit: r.limit, from: r.source, &r.action) }
      self
    end
    def compile!
      @rules.freeze
      @events.freeze
      freeze
    end
    private
    def validate_source(source)
      return if source.nil?
      raise ArgumentError, 'source is not in the wait' unless @sources&.any? { |s| s.equal?(source) }
    end
    def event(type, source, action)
      validate_source(source)
      key = [type, source]
      raise ArgumentError, "duplicate #{type} handler" if @events.key?(key)
      @events[key] = action
      self
    end
  end
  class RuleSet
    attr_reader :rules
    def initialize(&block)
      patterns = PatternSet.new
      block.parameters.empty? ? patterns.instance_exec(&block) : block.call(patterns)
      raise ArgumentError, 'RuleSets contain text rules only' unless patterns.events.empty?
      @rules = patterns.rules.freeze
      freeze
    end
  end
end
