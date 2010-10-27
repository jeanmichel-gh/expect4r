class Expect4r::J < ::Expect4r::BaseObject
  include Expect4r
  include Expect4r::Router::Error
  include Expect4r::Router::Common
  include Expect4r::Router::Common::Modes
  include Expect4r::Router::Junos::Modes
  include Expect4r::Router::Junos::Show
  include Expect4r::Router::Junos::Ping
  
  def initialize(*args)
    super
    @ps1 = /(^|\r\r)([-a-zA-z@_~=\.\(\)\d]+(>|\#|%)|%|\$) $/
    @more =  /---\(more(| \d+\%)\)---/
  end
  
  def login(arg={})
    super(spawnee, arg)
    exec 'set cli screen-length 0'
    self
  end
  
  def console?
    @port>0
  end
  
  def putline(line,arg={})
    o, rc = super
    raise SyntaxError.new(self.class.to_s, line) if o.join =~ /(unknown command|syntax error)\./
    o
  end
  
  def top
    putline 'top'
  end
  
  def exit
    putline 'exit'
  end
  
  def commit(arg={})
    return unless config?
    @matches << [/Exit with uncommitted changes.+\(yes\)/, 'yes']
    output = putline "commit", arg
    if /error: configuration check-out failed/.match(output.join)
      putline 'rollback'
      raise SemanticError.new(self.class.to_s, output)
    end
    output
  end
  
  private

end
