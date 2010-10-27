
require 'router/cisco/common/common'

class Expect4r::Iox < ::Expect4r::BaseObject
  
  include Expect4r
  include Expect4r::Router
  include Expect4r::Router::Common
  include Expect4r::Router::Common::Modes
  include Expect4r::Router::CiscoCommon
  include Expect4r::Router::Iox::Modes
  include Expect4r::Router::CiscoCommon::Show
  include Expect4r::Router::CiscoCommon::Ping
  
  def initialize(*args)
    super
    @ps1 = /(.*)(>|#|\$)\s*$/
    @more = / --More-- /
  end
  
  def login(arg={})
    super(spawnee, arg)
    config 'no logging console' if port>0
    exec "terminal len 0\nterminal width 0"
    self
  end
  
  def commit(arg={})
    return unless config?
    output = putline "commit", arg
    if /\% Failed to commit/.match(output.join)
      err = show_configuration_failed
      abort_config
      raise Iox::SemanticError.new(self.class.to_s, show_configuration_failed)
    end
    output
  end
  
  def putline(line,*args)
    output, rc = super
    raise SyntaxError.new(self.class.to_s, line) if output.join =~ /\% Invalid input detected at/
    output
  end

  private
  
  def abort_config
    return unless config?
    putline 'abort' # make sure buffer config is cleaned up.
    nil
  end

  def show_configuration_failed
    putline 'show configuration failed'
  end
  
end
