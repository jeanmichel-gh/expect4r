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
  
  class IoxError < RuntimeError
    def initialize(txt)
      @txt = txt
    end
  end
  class InvalidInputError < IoxError
    def invalid_input
      "\nCONFIG ERROR! (SyntaxError).\n'% Invalid Input' detected.\n=> #{@txt} <=\n"
    end
  end
  class CommitError < IoxError
    def error_msg
      %|\nCONFIG ERROR! (SemanticError).\nThe '% Failed to commit' error message was detected.\nAll changes made have been reverted.|
    end
    def show_configuration_failed
      puts @txt
    end
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
    output, rc = super
    raise InvalidInputError.new(line) if output.join =~ /\% Invalid input detected at/
    output
  end
  
  def commit(arg={})
    return unless config?
    output = putline "commit", arg
    if /\% Failed to commit/.match(output.join)
      err = show_configuration_failed
      # putline 'abort' # make sure buffer config is cleaned up.
      raise Iox::CommitError.new(show_configuration_failed)
    end
    output
  end
  
  def abort_config
    return unless config?
    putline 'abort' # make sure buffer config is cleaned up.
    nil
  end

  private
  
  def show_configuration_failed
    putline 'show configuration failed'
  end
  
end
