
module Expect4r::Router::Vyatta
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
  
  # count | match | no-match | no-more | more
  def method_missing(name, *args, &block)
    @invalid_inputs ||=[]
    super if @invalid_inputs.include?(name.to_s)
    cmd = name.to_s.split('_').join(' ')
    cmd += ""
  end

end
end
