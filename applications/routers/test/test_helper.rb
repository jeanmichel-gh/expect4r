# frozen_string_literal: true
require 'test/unit'
require 'expect4r'
require 'rbconfig'
require 'socket'
require 'stringio'
require 'tmpdir'
require 'timeout'

class RouterApplicationTest < Test::Unit::TestCase
  def with_input(bytes = '', eof: false, **options)
    left, right = Socket.pair(:UNIX, :STREAM, 0)
    right.write(bytes) unless bytes.empty?
    right.close_write if eof
    Expect4r.open(left, **options) { |session| yield session, right }
  ensure
    left&.close unless left&.closed?
    right&.close unless right&.closed?
  end
  def child(code, **options, &block)
    Expect4r.spawn(RbConfig.ruby, '-e', "$stdout.sync=true; #{code}", **options, &block)
  end
end
