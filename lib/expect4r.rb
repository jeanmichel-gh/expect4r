require 'expect/io'
require 'misc/passwd'

module Expect4r

  autoload :Iox,    'router/cisco/iox/iox'
  autoload :Ios,    'router/cisco/ios/ios'
  autoload :J,      'router/juniper/junos/junos'
  autoload :Shell,  'misc/shell'
  autoload :RShell, 'misc/shell'

  module Router
    autoload :Common, 'router/common'
    module Common
      autoload :Modes, 'router/modes'
    end
    module Error
      autoload :RouterError,    'router/error'
      autoload :SyntaxError,    'router/error'
      autoload :SemanticError,  'router/error'
      autoload :PingError,      'router/error'
    end
    module CiscoCommon
      autoload :Show, 'router/cisco/common/show'
      autoload :Ping, 'router/cisco/common/ping'
    end
    module Ios
      autoload :TermServer, 'router/cisco/ios/termserver'
      autoload :Modes, 'router/cisco/ios/modes'
    end
    module Iox
      autoload :Modes, 'router/cisco/iox/modes'
    end
    module Junos
      autoload :Modes, 'router/juniper/junos/modes'
      autoload :Show,  'router/juniper/junos/show'
      autoload :Ping, 'router/juniper/junos/Ping'
    end
  end

end

if __FILE__ == $0
  module Expect4r
    p Expect4r::Iox.new_ssh 'hostname', 'username'
    p Expect4r::Iox.new_telnet 'hostname', 'username'
    p Expect4r::Ios.new_ssh 'hostname', 'username'
    p Expect4r::J.new_ssh 'hostname', 'username'
    p Expect4r::Shell.new
  end
end
