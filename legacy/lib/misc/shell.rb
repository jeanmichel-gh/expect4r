module Expect4r
  class Shell < Expect4r::Base
    def initialize()
      super
      ENV['PROMPT_COMMAND']="date +%k:%m:%S"
      ENV['PS1']="shell>"
      @ps1 = /shell>$/
      @shell = ENV['SHELL'] || 'bash'
      login
    end
    def login
      spawn @shell
    end
  end
  class RShell < ::Expect4r::BaseLoginObject
    def initialize(*args)
      super
      default_ps1
    end
    def logout
      default_ps1
      super
    end
    def login(arg={}) 
      super(spawnee, arg)
      cmd %{export COLUMNS=1024}
    end
    # FIXME: 1.9.2 bug: 
    # It calls LoginBaseOject#login() instead of calling J#login()
    # modified login_by_proxy to call _login_ seems to work.
    alias :_login_ :login
    
    def ps1=(val)
      # Assumes bash
      @ps1_bis = /#{val}$/
      cmd %? export PS1='#{val}' ?
      @ps1 = @ps1_bis
    end
    def cmd(*args)
      exp_send *args
    end

    private
    
    def default_ps1
      @ps1 = /.+[^\#](\#|\$)\s+$/
    end
  end
end

__END__


cmd %? PROMPT_COMMAND="echo -n [$(date +%k:%m:%S)]: && pwd" && export PS1='#{val}' ?
