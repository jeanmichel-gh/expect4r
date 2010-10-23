require 'expect/io_interact'
require 'router/common'
require 'router/cisco/ios/ios'
require 'router/cisco/ios/modes'
require 'router/cisco/ios/termserver'
require 'router/cisco/common/common'
require 'router/cisco/common/show'
require 'router/cisco/common/ping'
require 'misc/passwd'

class Ios < ::Interact::InteractBaseObject

  include Interact
  include Interact::Router::Common
  include Interact::Router::Common::Modes
  include Interact::Router::Ios::Modes
  include Interact::Router::CiscoCommon
  include Interact::Router::CiscoCommon::Show
  include Interact::Router::CiscoCommon::Ping
  include Interact::Router::Ios::TermServer
  
  class IosError < RuntimeError
    def initialize(txt)
      @txt = txt
    end
  end
  
  class SyntaxError < IosError
    def error_msg
      "\nSyntaxError.\n'% Invalid Input' detected.\n=> #{@txt} <=\n"
    end
  end
  class InvalidInputError < SyntaxError
  end
  
  def initialize(*args)
    super
    @ps1 = /(.*)(>|#|\$)\s*$/
    @more = / --More-- /
  end
  
  def enable
    @enable_password ||= @pwd
    @matches << [/^Password: $/, enable_password ]
    send 'enable'
  end
  
  def enable_password
    @enable_password ||= @pwd  # FIXME
    Interact.decipher(@pwd)    # password is ciphered ...
  end
  
  def login
    super(spawnee)
    enable
    exec "term len 0\nterm width 0"
    self
  end

  def putline(line,*args)
    output, rc = super
    raise SyntaxError.new(line) if output.join =~ /\% Invalid input detected at/
    output
  end
    
end
