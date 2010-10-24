class Expect4r::Ios < ::Expect4r::BaseObject
  
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
    enable_pwd = [/^Password: $/, enable_password]
    @matches << enable_pwd
    exp_send 'enable'
  rescue 
    raise
  ensure
    @matches.delete enable_pwd
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
    return output unless error?(output)
    raise SyntaxError.new(self.class.to_s,line)
  end
  
  private
  
  if "a"[0]==97
    def string_start_with_pct_char?(s)
      return unless s
      s[0].chr == '%' if s[0]
    end
  else
    def string_start_with_pct_char?(s)
      return unless s
      s[0] == '%'
    end
  end
  
  def error?(output)
    string_start_with_pct_char?(output[-2]) || string_start_with_pct_char?(output[-3])
  end
  
end
