# frozen_string_literal: true
module Expect4r
  Result = Data.define(:status, :name, :pattern_index, :pattern, :session, :before,
                       :match, :after, :captures, :reason, :elapsed, :pending, :staged) do
    def initialize(status:, name: nil, pattern_index: nil, pattern: nil, session: nil,
                   before: ''.b, match: nil, after: nil, captures: [], reason: nil, elapsed: 0, pending: {}, staged: {})
      copy = ->(s) { s.nil? ? nil : String.new(s).b.freeze }
      super(status:, name:, pattern_index:, pattern:, session:, before: copy.call(before),
            match: copy.call(match), after: copy.call(after),
            captures: captures.map { |c| copy.call(c) }.freeze, reason:, elapsed:,
            pending: pending.transform_values { |s| copy.call(s) }.freeze,
            staged: staged.transform_values { |s| copy.call(s) }.freeze)
    end
    def matched? = status == :matched
    def timeout? = status == :timeout
    def full_buffer? = status == :full_buffer
    def eof? = status == :eof
    def inspect = "#<Expect4r::Result status=#{status} name=#{name.inspect} reason=#{reason.inspect}>"
    alias to_s inspect
    def pretty_print(printer) = printer.text(inspect)
  end
  InteractionResult = Data.define(:reason, :session, :elapsed, :pending_input)
end
