# frozen_string_literal: true
require 'expect4r'
module Expect4rRouters
  class Error < Expect4r::Error; end
  %i[AuthenticationError HostKeyError CommandError CommandTimeout ConnectionLost
     OutputLimitError ConfigurationError].each { |name| const_set(name, Class.new(Error)) }
  BusySessionError = Expect4r::BusySessionError
  UnsupportedOperation = Expect4r::UnsupportedOperation
end
