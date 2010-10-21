require 'expect/io_interact'
require 'router/common'
require 'router/base_router'
require 'router/cisco/iox/iox'
require 'router/cisco/iox/modes'
require 'router/cisco/common/common'
require 'router/cisco/common/show'
require 'router/cisco/common/ping'
require 'misc/passwd'

class Iox < ::Interact::Router::BaseRouter
  
  include Interact
  include Interact::Router::Common
  include Interact::Router::Common::Modes
  include Interact::Router::CiscoCommon
  include Interact::Router::Iox::Modes
  include Interact::Router::CiscoCommon::Show
  include Interact::Router::CiscoCommon::Ping
  
  class IoxError < RuntimeError
    def initialize(txt)
      @txt = txt
    end
  end
  
  class SyntaxError < IoxError
    def invalid_input
      "\nCONFIG ERROR! (SyntaxError).\n'% Invalid Input' detected.\n=> #{@txt} <=\n"
    end
  end
  
  class InvalidInputError < SyntaxError
  end
  
  class SemanticError < IoxError
    def error_msg
      %|\nCONFIG ERROR! (SemanticError).\nThe '% Failed to commit' error message was detected.\nAll changes made have been reverted.|
    end
    def show_configuration_failed
      puts @txt
    end
  end
  
  class CommitError < SemanticError
  end
  
  class PingError < ::Iox::IoxError
    def error_message
      %|\nPING FAILURE! \n#{@txt}\n|
    end
  end
  
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
