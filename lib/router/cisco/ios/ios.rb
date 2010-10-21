require 'expect/io_interact'
require 'router/common'
require 'router/base_router'
require 'router/cisco/ios/ios'
require 'router/cisco/ios/modes'
require 'misc/passwd'

class Ios < ::Interact::Router::BaseRouter

  include Interact
  include Interact::Router::Common
  include Interact::Router::Common::Modes
  include Interact::Router::Ios::Modes
  # TODO: include Interact::Router::Ios::Show
  
  class IosError < RuntimeError
    def initialize(txt)
      @txt = txt
    end
  end
  class SyntaxError < IosError
    def invalid_input
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
    @enable_password = 'lab'
    @matches << [/^Password: $/, @enable_password ]
    send 'enable'
  end
  
  def login
    super("telnet #{@host}")
    send %{
      term len 0
      term width 0
    }
  end
  
  def putline(line,*args)
    output, ev = super
    raise InvalidInputError.new(output.join("\n")) if output.join =~ /% Invalid input\./
    output
  end
end
