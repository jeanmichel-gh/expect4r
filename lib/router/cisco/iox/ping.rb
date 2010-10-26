require 'router/error'

module Expect4r::Router::Iox
module Ping

  def ping(arg={})

    raise ArgumentError, "You must specify a target_ip_address" unless arg[:target_ip_address]

    pct_success = arg.delete(:pct_success) || 100
    target_ip_address = [:target_ip_address]

    if (arg.keys - [:target_ip_address]).empty?

      output = exec "ping #{arg[:target_ip_address]}", arg

    else

      @matches = Set.new

      set_ping_base_matches arg
      set_ping_extended_matches arg
      set_ping_sweep_matches arg

      output = exec "ping", arg
      
    end

    r = output[0].find { |x| x =~/Success.*[^\d](\d+) percent \((\d+)\/(\d+)\)/}

    if r && 
      Regexp.last_match(1) && 
      Regexp.last_match(2) && 
      Regexp.last_match(3)

      # TODO: use getter host instead of @host.
      if $1.to_i < pct_success
        raise ::Expect4r::Router::Error::PingError.new(@host, target_ip_address, pct_success, $1.to_i, $2.to_i,$3.to_i, output)
      else
        [$1.to_i,[$2.to_i,$3.to_i],output]
      end

    else
      raise ::Expect4r::Router::Error::PingError.new(@host, target_ip_adress, pct_success, $1.to_i, $2.to_i,$3.to_i, output)
    end

  end

private

  def set_ping_base_matches(arg={})
    target_ip_address = arg[:target_ip_address]
    protocol          = arg[:protocol]          || ''
    repeat_count      = arg[:repeat_count]      || ''
    datagram_size     = arg[:datagram_size]     || ''
    timeout           = arg[:timeout]           || ''
    @matches << [/Protocol.+\: $/, protocol]
    @matches << [/Target IP address\: $/, target_ip_address]
    @matches << [/Repeat count.+\: $/, repeat_count]
    @matches << [/Datagram size.+\: $/, datagram_size]
    @matches << [/Timeout.+\: $/, timeout]
  end

  def set_ping_extended_matches(arg={})
    extended_keys = [:source_address, :tos, :df, :pattern]
    if (extended_keys & arg.keys).empty? and arg[:source_address]
      @matches << [/Extended.+\: $/, '']
    else
      src_adr =  arg[:source_address]
      tos     =  arg[:tos]     || ''
      df      =  arg[:df]      || ''
      pattern =  arg[:pattern] || ''
      @matches << [/Extended.+\: $/, 'yes']
      @matches << [/Source address or interface\: $/, src_adr]
      @matches << [/Type of service.+\: $/, tos]
      @matches << [/Set DF bit.+\: $/, df]
      @matches << [/Data pattern.+\: $/, pattern]
      @matches << [/Validate reply.+\: $/, '']     #TODO
      @matches << [/Loose, Strict,.+\: $/, '']     #TODO
    end
  end

  def set_ping_sweep_matches(arg={})
    sweep_keys = [:sweep_min_size, :sweep_max_size, :sweep_interval]
    if (sweep_keys & arg.keys).empty?
      @matches << [/Sweep range of sizes\? \[no\]\: $/, 'no']
    else
      min_size = arg[:sweep_min_size] || ''
      max_size = arg[:sweep_max_size] || ''
      interval = arg[:sweep_interval] || ''
      @matches << [/Sweep range of sizes\? \[no\]\: $/, 'yes']
      @matches << [/Sweep min size.+\: $/, min_size]
      @matches << [/Sweep max size.+\: $/, max_size]
      @matches << [/Sweep interval.+\: $/, interval]
    end
  end

end

end

__END__

p.ping :target_ip_address => '171.70.245.44'
p.ping :target_ip_address => '171.70.245.44', :sweep_max_size=> 1512
p.ping :target_ip_address => '171.70.245.44', :source_address => ' 172.20.186.101'

