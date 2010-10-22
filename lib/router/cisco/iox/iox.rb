require 'expect/io_interact'
require 'router/common'
require 'router/error'
require 'router/cisco/iox/iox'
require 'router/cisco/iox/modes'
require 'router/cisco/common/common'
require 'router/cisco/common/show'
require 'router/cisco/common/ping'
require 'misc/passwd'

class Iox < ::Interact::InteractBaseObject
  
  include Interact
  include Interact::Router
  include Interact::Router::Common
  include Interact::Router::Common::Modes
  include Interact::Router::CiscoCommon
  include Interact::Router::Iox::Modes
  include Interact::Router::CiscoCommon::Show
  include Interact::Router::CiscoCommon::Ping
  
  def initialize(*args)
    super
    @ps1 = /(.*)(>|#|\$)\s*$/
    @more = / --More-- /
  end
  
  def login
    super(spawnee)
    config 'no logging console' if port>0
    exec %\
      terminal len 0
      terminal width 0
    \
  end
  
  def commit(arg={})
    return unless config?
    output = putline "commit", arg
    if /\% Failed to commit/.match(output.join)
      err = show_configuration_failed
      abort_config
      raise Iox::SemanticError.new(show_configuration_failed)
    end
    output
  end
  
  def putline(line,*args)
    output, rc = super
    raise SyntaxError.new(line) if output.join =~ /\% Invalid input detected at/
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
