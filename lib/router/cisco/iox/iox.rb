require 'expect/io_interact'
require 'router/common'
require 'router/cisco/iox/iox'
require 'router/cisco/iox/modes'
require 'router/cisco/iox/show'
require 'misc/passwd'

class Iox
  include Interact
  include Interact::Router::Common
  include Interact::Router::Common::Modes
  include Interact::Router::Iox::Modes
  include Interact::Router::Iox::Show
  
  class Error < RuntimeError
  end
  class BogusCliMode < Error
  end
  class BogusMode < Error
    # TODO see to print a nice error message with actual mode and mode required.
  end
  class CliError < Error
    def initialize(arg)
      s = arg.is_a?(Array) ? arg.join : arg
      super s.gsub(/\r\n/,"\n")
    end
  end
  class ConfigError < Error
    def initialize(arg)
      s = arg.is_a?(Array) ? arg.join : arg
      super s.gsub(/\r\n/,"\n")
    end
  end
  class UnknownCommandError < CliError
  end
  class SyntaxError < CliError
  end
  
  class << self
    def new_telnet(*args)
      new :telnet, *args
    end
    def new_ssh(*args)
      new :ssh, *args
    end
  end
  
  attr_reader :host, :user, :method, :port
  alias :username :user
  alias :hostname :host
  def initialize(*args)
    if args.size>2 and args[1].is_a?(String)
      @method, host, @user, pwd = args
    elsif args.size ==2 and args[1].is_a?(Hash) and args[0].is_a?(Symbol)
      @method = args[0]
      host = args[1][:host] || args[1][:hostname]
      @user = args[1][:user]|| args[1][:username]
      pwd  = args[1][:pwd]  || args[1][:password]
    end
    @host, port = host.split
    @port = port.to_i
    @pwd  = Interact.cipher(pwd) if pwd
    @prompt = /(.*)(>|#|\$)\s*$/
    @more = / --More-- /
  end
  
  def login
    super(spawnee)
    send %{
      term len 0
      term width 0
    }
  end
  
  def putline(line,*args)
    output, ev = super
    raise IOX::InvalidInput.new(output.join) if output.join =~ /% Invalid input\./
    output
  end
  
end
