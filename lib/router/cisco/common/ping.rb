require 'router/error'

module Interact
module Router
module CiscoCommon
module Ping
  include ::Interact::Router::Error
    
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
    r = output[0].find { |x| p x ; x =~/Success.*[^\d](\d+) percent \((\d+)\/(\d+)\)/}
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
end
end

__END__

(rname, dest, exp_pct, act_pct, sent, recv)

irb(main):110:0> p @x.ping :dest=>'172.20.186.101'
["100", ["5", "5"], ["ping 172.20.186.101\r\n", "\rTue Oct 19 16:11:02.240 UTC\r\n", "Type escape sequence to abort.\r\n", "Sending 5, 100-byte ICMP Echos to 172.20.186.101, timeout is 2 seconds:\r\n", "!!!!!\r\n", "Success rate is 100 percent (5/5), round-trip min/avg/max = 1/1/3 ms\r\n", "RP/0/0/CPU0PU0:Dijon-rp0#"]]
=> nil

irb(main):133:0> p @x.ping :dest=>'172.20.186.101', :pct_success=>120
Exception `Interact::Router::Iox::Ping::PingError' at ./lib/router/cisco/iox/ping.rb:29 - Success rate is 100 percent (5/5)
Exception `Interact::Router::Iox::Ping::PingError' at /System/Library/Frameworks/Ruby.framework/Versions/1.8/usr/lib/ruby/1.8/irb/workspace.rb:81 - Success rate is 100 percent (5/5)
Interact::Router::Iox::Ping::PingError: Success rate is 100 percent (5/5)
	from ./lib/router/cisco/iox/ping.rb:29:in `ping'
	from (irb):133
	from (null):0
irb(main):134:0> p @x.ping :dest=>'172.20.186.101', :pct_success=>101
Exception `Interact::Router::Iox::Ping::PingError' at ./lib/router/cisco/iox/ping.rb:29 - Success rate is 100 percent (5/5)
Exception `Interact::Router::Iox::Ping::PingError' at /System/Library/Frameworks/Ruby.framework/Versions/1.8/usr/lib/ruby/1.8/irb/workspace.rb:81 - Success rate is 100 percent (5/5)
Interact::Router::Iox::Ping::PingError: Success rate is 100 percent (5/5)
	from ./lib/router/cisco/iox/ping.rb:29:in `ping'
	from (irb):134
	from (null):0
irb(main):135:0> p @x.ping :dest=>'172.20.186.101', :pct_success=>100
[100, [5, 5], ["ping 172.20.186.101\r\n", "\rTue Oct 19 16:20:22.223 UTC\r\n", "Type escape sequence to abort.\r\n", "Sending 5, 100-byte ICMP Echos to 172.20.186.101, timeout is 2 seconds:\r\n", "!!!!!\r\n", "Success rate is 100 percent (5/5), round-trip min/avg/max = 1/1/2 ms\r\n", "RP/0/0/CPU0:Dijon-rp0#"]]
=> nil
irb(main):136:0> p @x.ping :dest=>'172.20.186.101', :pct_success=>99
[100, [5, 5], ["ping 172.20.186.101\r\n", "\rTue Oct 19 16:20:27.828 UTC\r\n", "Type escape sequence to abort.\r\n", "Sending 5, 100-byte ICMP Echos to 172.20.186.101, timeout is 2 seconds:\r\n", "!!!!!\r\n", "Success rate is 100 percent (5/5), round-trip min/avg/max = 1/1/2 ms\r\n", "RP/0/0/CPU0:Dijon-rp0#"]]
=> nil







ping :host=> 171.70.20.25.44, :repeat=>10, :size=>200, :timeout=>2


RP/0/0/CPU0:Dijon-rp0#ping 
Tue Oct 19 12:24:23.407 UTC
Protocol [ipv4]:      
Target IP address:  171.70.245.44
Repeat count [5]: 20
Datagram size [100]: 200
Timeout in seconds [2]: 1
Extended commands? [no]: 
Sweep range of sizes? [no]: 
Type escape sequence to abort.
Sending 20, 200-byte ICMP Echos to 171.70.245.44, timeout is 1 seconds:
!!!!!!!!!!!!!!!!!!!!
Success rate is 100 percent (20/20), round-trip min/avg/max = 1/1/4 ms
RP/0/0/CPU0:Dijon-rp0#
