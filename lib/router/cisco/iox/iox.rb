require 'expect/io_interact'
require 'router/common'
require 'router/cisco/iox/iox'
require 'router/cisco/iox/modes'
require 'router/cisco/iox/show'

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
  
  def initialize(method, host, user, pwd, port=0)
    @method = method
    @host = host
    @user = user
    @pwd  = Interact.cipher(pwd) if pwd
    @prompt = /(.*)(>|#|\$)\s*$/
    @more = / --More-- /
    @port = port
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
