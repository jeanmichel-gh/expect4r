require 'expect/io_interact'
require 'rubygems'
require 'highline/import'
require 'cisco_ios/ios_modes'

class Ios
  include IosModes
  class Error < RuntimeError
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
  
  include Interact
  # include IoxModes
  
  def initialize(host, user, pwd)
    @host = host
    @user = user
    @pwd  = pwd
    @prompt = /(.*)(>|#|\$)\s*$/
    @more = / --More-- /
  end
  
  def spawnee_username
    @user
  end

  def spawnee_password
    if @pwd == '*ask_me*'
      ask("Enter your password:  ") { |q| q.echo = "X" }
    else  
      @pwd
    end
  end

  def spawnee_prompt
    @prompt
  end
    
  def login
    super("telnet #{@host}")
    putlines %{
      term len 0
      term width 0
    }
  end
  
  def io_escape_char_cb
    #DO Nothing if telnet not from console.
  end
  
  def putline(line,*args)
    output, ev = super
    raise IOX::InvalidInput.new(output.join) if output.join =~ /% Invalid input\./
    output
  end
end
