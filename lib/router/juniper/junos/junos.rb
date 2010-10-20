
require 'expect/io_interact'
require 'router/common'
require 'router/juniper/junos/modes'

class J
  class Error < RuntimeError
  end
  class CliError < Error
    def initialize(s)
      super s.gsub(/\r/,"\n")
    end
  end
  class ConfigError < Error
  end
  class BogusCliMode < Error
  end
  class UnknownCommandError < CliError
  end
  class SyntaxError < CliError
  end
end

class J
  include Interact
  include Interact::Router::Common
  include Interact::Router::Common::Modes
  include Interact::Router::Junos::Modes

  def J.new_telnet(*args)
    new :telnet, *args
  end
  
  def J.new_ssh(*args)
    new :ssh, *args
  end
  
  attr_reader :host, :port, :method
  
  def initialize(method, host, user, pwd, port=0)
    @method = method
    @host = host
    @user = user
    @pwd  = pwd
    @port = port
    @prompt = /(^|\r\r)([-a-zA-z@_~=\.\(\)\d]+(>|\#|%)|%|\$) $/
    @more =  /---\(more(| \d+\%)\)---/
  end
  def login
    ENV['TERM']='dumb'
    super("ssh #{@user}@#{@host}")
    send %{
      set cli screen-length 0
      set cli complete-on-space off
    }
  end
  
  def termserver?
    @port>0
  end
  
  def putline(line,arg={})
    o, rc = super
    raise UnknownCommandError.new(o.join) if o.join =~ /(unknown command|syntax error)\./
    raise SyntaxError.new(o.join) if o.join =~ /syntax error/
    o
  end
  def top
    putline 'top'
  end
  def exit
    putline 'exit'
  end
  
  private

end
