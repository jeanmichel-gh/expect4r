require 'router/error'

module Expect4r::Router::Vyatta
module Ping

  # Adds a ping method to V class:
  #
  # Options are:
  # * <tt>:count</tt> or <tt>:repeat_count</tt>
  # * <tt>:size</tt> or <tt>:datagram_size</tt>
  # * <tt>:datagram_size</tt> or <tt>:size</tt>
  # * <tt>:timeout</tt>
  # * <tt>:tos</tt>
  # * <tt>:ttl</tt>
  # * <tt>:pattern</tt>
  # * <tt>:pct_success</tt> - default is 99.
  #
  # Option examples:
  #   :count => 10
  #   :timeout => 1
  #   :size=> 512
  #   :protocol=> 'ipv4', :count=> 20, :size=> 1500, :timeout=>5, :ttl=>16
  # Example:
  #    v.ping('192.168.129.1', :count=>10, :size=>256)  { |r| r.interact }
  #--
  # PING 192.168.129.1 (192.168.129.1) 56(84) bytes of data.
  # 64 bytes from 192.168.129.1: icmp_req=1 ttl=64 time=0.173 ms
  # 64 bytes from 192.168.129.1: icmp_req=2 ttl=64 time=0.132 ms
  # 64 bytes from 192.168.129.1: icmp_req=3 ttl=64 time=0.144 ms
  # 64 bytes from 192.168.129.1: icmp_req=4 ttl=64 time=0.128 ms
  # 64 bytes from 192.168.129.1: icmp_req=5 ttl=64 time=0.225 ms
  #
  # --- 192.168.129.1 ping statistics ---
  # 5 packets transmitted, 5 received, 0% packet loss, time 3996ms
  # rtt min/avg/max/mdev = 0.128/0.160/0.225/0.037 ms
  # vyatta@vyatta2:~$ 
  #++
  def ping(host, arg={}, &on_error)

    pct_success = arg.delete(:pct_success) || 99

    output = exec(ping_cmd(host, arg), arg)

    r = output[0].find { |x| x =~/(\d+) packets transmitted, (\d+) received, (\d+)\% packet loss/}

    if r && 
      Regexp.last_match(1) && 
      Regexp.last_match(2) && 
      Regexp.last_match(3)

      success = 100 - $3.to_i
      tx = $2.to_i
      rx = $3.to_i
      
      if (100 - $3.to_i) < pct_success
        raise ::Expect4r::Router::Error::PingError.new(@host, host, pct_success, tx, rx, output)
      else
        [$1.to_i,[$2.to_i,$3.to_i],output]
      end

    else

      if on_error
        on_error.call(self)
      else
        raise ::Expect4r::Router::Error::PingError.new(@host, host, pct_success, $1.to_i, tx, rx, output)
      end

    end

  end

private

  # vyatta@vyatta2:~$ /bin/ping 
  # Usage: ping [-LRUbdfnqrvVaAD] [-c count] [-i interval] [-w deadline]
  #             [-p pattern] [-s packetsize] [-t ttl] [-I interface]
  #             [-M pmtudisc-hint] [-m mark] [-S sndbuf]
  #             [-T tstamp-options] [-Q tos] [hop1 ...] destination
  def ping_cmd(host, arg={})
    arg = {:count=>5}.merge(arg)
    cmd = "/bin/ping"
    cmd += " -c #{arg[:count] || arg[:repeat_count]}"   if arg[:count] || arg[:repeat_count]
    cmd += " -s #{arg[:size]   || arg[:datagram_size]}" if arg[:size]  || arg[:datagram_size] 
    cmd += " -p #{arg[:pattern]}"                       if arg[:pattern]
    cmd += " -Q #{arg[:tos]}"                           if arg[:tos]
    cmd += " -t #{arg[:ttl]}"                           if arg[:ttl]
    cmd += " -S #{arg[:sndbuf]}"                        if arg[:sndbuf]
    cmd += " -c #{arg[:intf] || arg[:interface]}"       if arg[:intf] || arg[:interface]
    cmd += " -w #{arg[:deadline]}"                      if arg[:deadline]
    cmd += " #{host}"
    cmd
  end

end
end
