module Expect4r::Router::CiscoCommon
module Show

  def show(s, arg={})
    output = []
    nlines = 0
    s.each_line { |l|
      next unless l.strip.size>0
      output << exec("show #{l}", arg) if l.strip.size>0
      nlines +=1
    }
    nlines > 1 ? output : output[0]
  end
  
end
end
