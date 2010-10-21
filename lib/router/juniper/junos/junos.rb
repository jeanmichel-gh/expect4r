
require 'expect/io_interact'
require 'router/common'
require 'router/base_router'
require 'router/juniper/junos/modes'

class J < ::Interact::Router::BaseRouter
  
  class JError < RuntimeError
    def initialize(txt)
      @txt = txt
    end
  end
  class SyntaxError < JError
    def invalid_input
      "\nSyntaxError.\n'% Invalid Input' detected.\n=> #{@txt} <=\n"
    end
  end

  class SemanticError < JError
    def error_msg
      %|\nSemanticError.\nThe '% Failed to commit' error message was detected.\nAll changes made have been reverted.|
    end
    def show_configuration_failed
      puts @txt
    end
  end
  
  class PingError < JError
    def error_msg
      %|\nPING FAILURE! \n#{@txt}\n|
    end
  end
  
  
  class Error < RuntimeError
  end
  class CliError < Error
    def initialize(s)
      super s.gsub(/\r/,"\n")
    end
  end
end

class J 
  include Interact
  include Interact::Router::Common
  include Interact::Router::Common::Modes
  include Interact::Router::Junos::Modes
  
  def initialize(*args)
    super
    @ps1 = /(^|\r\r)([-a-zA-z@_~=\.\(\)\d]+(>|\#|%)|%|\$) $/
    @more =  /---\(more(| \d+\%)\)---/
  end
  
  def login
    ENV['TERM']='dumb'
    super(spawnee)
    send %{
      set cli screen-length 0
      set cli complete-on-space off
    }
  end
  
  def console?
    @port>0
  end
  
  def putline(line,arg={})
    o, rc = super
    raise SyntaxError.new(o.join("\n")) if o.join =~ /(unknown command|syntax error)\./
    o
  end
  
  def top
    putline 'top'
  end
  
  def exit
    putline 'exit'
  end
  
  def commit(arg={})
    return unless config?
    output = putline "commit", arg
    if /\% Failed to commit/.match(output.join)
      putline 'rollback'
      raise CommitError.new(output)
    end
    output
  end
  
  private

end
