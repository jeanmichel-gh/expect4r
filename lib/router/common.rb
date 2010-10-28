
require 'rubygems'
require 'highline/import'
require 'misc/passwd'

module Expect4r::Router
module Common

  def console?
    @port.to_i > 0
  end

  def io_escape_char_cb
    putc "\n" if console?
  end

end
end
