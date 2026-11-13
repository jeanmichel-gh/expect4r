module Expect4r::Router::Ios
module TermServer
  
  def powercycle(lineno)
    config "line #{lineno}\nmodem dtr\nmodem dtr-active"
    sleep 2
    config "line #{lineno}\nno modem dtr\nno modem dtr-active"
  end
  def clear_line(lineno)
    confirm = [/\[confirm\]/, ""]
    @matches << confirm
    putline "clear line #{lineno}"
  rescue Expect4r::Router::Error::SyntaxError => e
    puts e.err_msg
  ensure
    @matches.delete confirm
  end
  
end
end
