require 'expect/io'
require 'router/common'
require 'router/error'
require 'router/cisco/ios/ios'
require 'router/cisco/ios/modes'
require 'router/cisco/ios/termserver'
require 'router/cisco/common/common'
require 'router/cisco/common/show'
require 'router/cisco/common/ping'
require 'misc/passwd'

class Ios < ::Expect4r::BaseObject

  include Expect4r
  include Expect4r::Router::Common
  include Expect4r::Router::Common::Modes
  include Expect4r::Router::Ios::Modes
  include Expect4r::Router::CiscoCommon
  include Expect4r::Router::CiscoCommon::Show
  include Expect4r::Router::CiscoCommon::Ping
  include Expect4r::Router::Ios::TermServer
  
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
    Expect4r.decipher(@pwd)    # password is ciphered ...
  end
  
  def login
    super(spawnee)
    enable
    exec "term len 0\nterm width 0"
    self
  end

  def putline(line,*args)
    output, rc = super
    return output unless output [-2][0] == '%'
    raise SyntaxError.new(self.class.to_s,line)
    output
  end
    
end
