require 'router/error'

module Expect4r::Router::CiscoCommon
module Ping
  include ::Expect4r::Router::Error
  def ping(arg={})
    if arg.is_a?(Hash)
      arg = {:pct_success=>100}.merge(arg) 
      pct_success = arg[:pct_success]
    else
      pct_success = 100
    end
    case arg
    when String
      dest = arg
    when Hash
      dest = arg[:dest]
    else
      raise ArgumentError, "Invalid argument: #{arg.inspect}"
    end
    output = exec "ping #{dest}", arg
    r = output[0].find { |x| x =~/Success.*[^\d](\d+) percent \((\d+)\/(\d+)\)/}
    if r && 
       Regexp.last_match(1) && 
       Regexp.last_match(2) && 
       Regexp.last_match(3)
       
       if $1.to_i < pct_success
         raise PingError('router name here', dest, pct_success, $1.to_i, $2.to_i,$3.to_i, output)
       else
         [$1.to_i,[$2.to_i,$3.to_i],output]
       end
       
    else
      raise PingError.new('router name here', dest, pct_success, $1.to_i, $2.to_i,$3.to_i, output)
    end
  end
end
end
