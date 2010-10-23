
module Expect4r::Router::Junos
module Show

  def show(s, arg={})
    output = []
    s.each_line { |l|
      output << exec("show #{l}", arg) if l.strip.size>0
    }
    output
  end
  
  def method_missing(name, *args, &block)
    if name.to_s =~ /^show_/
      cmd = name.to_s.split('_').join(' ') + args.join(' ')
      output = __send__ :exec, cmd, *args
    else
      super
    end
  end
  
end
end
