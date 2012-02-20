class Expect4r::V < ::Expect4r::BaseLoginObject
  include Expect4r
  include Expect4r::Router::Error
  include Expect4r::Router::Common
  include Expect4r::Router::Common::Modes
  include Expect4r::Router::Vyatta::Modes
  include Expect4r::Router::Vyatta::Ping
  include Expect4r::Router::Vyatta::Show

  class << self
    # v = V.new_telnet 'hostname'
    def new_telnet(*args)
      if args.size==1 and args[0].is_a?(String)
        super :host=> args[0], :user=>'vyatta', :pwd=>'vyatta'
      else
        super
      end
    end

    # v = V.new_ssh 'hostname'
    def new_ssh(*args)
      if args.size==1 and args[0].is_a?(String)
        super :host=> args[0], :user=>'vyatta', :pwd=>'vyatta'
      else
        super
      end
    end
  end
  
  def initialize(*args)
    super
    @ps1 = /([A-z\d]+)@([A-z\d]+)(:[^\$]+|)(#|\$) $/
  end
  
  def login(arg={})
    super(spawnee, arg)
    putline "terminal length 0"
    putline "terminal width 0"
    self
  end
  alias :_login_ :login
  
  def putline(line,arg={})
    o, rc = super
    raise SyntaxError.new(self.class.to_s, line) if o.join =~ /(% unknown|Invalid command)/
    o
  end
  
  def top
    putline 'top'
  end
  
  def exit
    putline 'exit'
  end
    
  def exit_discard
    putline 'exit discard'
  end
    
  def commit(arg={})
    return unless config?
    @matches << [/Exit with uncommitted changes.+\(yes\)/, 'yes']
    output = putline "commit", arg
    if /error: configuration check-out failed/.match(output.join)
      rollack
      raise SemanticError.new(self.class.to_s, output)
    end
    output
  end
  
  private

end
