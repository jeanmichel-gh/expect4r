require 'router/cisco/common/common'

class Expect4r::Ios < ::Expect4r::BaseLoginObject
  
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
    
  def putline(line,*args)
    output, rc = super
    return output unless error?(output)
    raise BadPasswordError.new(self.class.to_s,line) if output =~ /Bad password/ 
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
    string_start_with_pct_char?(output[-2]) || 
    string_start_with_pct_char?(output[-3])
  end

  def method_missing(name, *args, &block)
    if name.to_s =~ /^show_/
      filters=[]
      if args.last.is_a?(Hash)
        _begin = args.last.delete(:begin) 
        _section = args.last.delete(:section)
        _count = args.last.delete(:count)
        _exclude = args.last.delete(:exclude)
        _include = args.last.delete(:include)
        filters << "| begin #{_begin}" if _begin
        filters << "| count #{_count}" if _count
        filters << "| section #{_section}" if _section
        filters << "| exclude #{_exclude}" if _exclude
        filters << "| include #{_include}" if _include
      end   
      cmd = name.to_s.split('_').join(' ')
      cmd += " " + filters.join(' ') if filters
      cmd.gsub!(/running config/, 'running-config')
      output = __send__ :exec, cmd, *args
    elsif name.to_s =~ /^shell_/
      cmd = name.to_s.split('_')[1..-1].join(' ') + args.join(' ')
      output = __send__ :shell, cmd, *args
    else
      super
    end
  end
  
end
