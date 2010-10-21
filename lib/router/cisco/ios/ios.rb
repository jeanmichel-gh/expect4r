require 'expect/io_interact'
require 'router/common'
require 'router/base_router'
require 'router/cisco/ios/ios'
require 'router/cisco/ios/modes'
require 'router/cisco/ios/termserver'
require 'router/cisco/common/common'
require 'router/cisco/common/show'
require 'router/cisco/common/ping'
require 'misc/passwd'

class Ios < ::Interact::Router::BaseRouter

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
    send %{
      term len 0
      term width 0
    }
  end
    
end
