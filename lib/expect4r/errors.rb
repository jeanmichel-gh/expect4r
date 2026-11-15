# frozen_string_literal: true
module Expect4r
  class Error < StandardError
    attr_reader :result, :command, :errno, :bytes_written, :buffer, :rejected, :progress
    def initialize(message = nil, result: nil, command: nil, errno: nil, bytes_written: 0,
                   buffer: nil, rejected: nil, progress: nil)
      @result, @command, @errno, @bytes_written = result, command, errno, bytes_written
      @buffer, @rejected, @progress = buffer, rejected, progress
      super(message || self.class.name.split('::').last)
    end
  end
  %i[SpawnError TransportError WriteTimeout BufferOverflow BufferProgressError EncodingError ExpectTimeout
     UnexpectedEOF BusySessionError ReentrancyError InvalidContinuation EmptyMatchError
     ResponseLimitError CleanupError UnsupportedOperation].each do |name|
    const_set(name, Class.new(Error))
  end
  class ReplayError < Error; end
  class ReplayFormatError < ReplayError; end
  class ReplayMismatchError < ReplayError; end
  class ReplayIncompleteError < ReplayError; end
  class CaptureError < Error; end
  class CaptureLimitError < CaptureError; end
  class CaptureSinkError < CaptureError; end
end
