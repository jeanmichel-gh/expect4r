require 'router/error'

module Expect4r::Router::CiscoCommon
module Ping
  include ::Expect4r::Router::Error
 
  # Adds a <tt>ping</tt> method to <tt>CiscoCommon::Ping mixin</tt>:
  #
  # Options are:
  # * <tt>:protocol</tt>
  # * <tt>:repeat_count</tt> or <tt>:count</tt>
  # * <tt>:datagram_size</tt> or <tt>:size</tt>
  # * <tt>:timeout</tt>
  # * <tt>:source_address</tt> 
  # * <tt>:tos</tt>
  # * <tt>:df</tt>
  # * <tt>:pattern</tt>
  # * <tt>:sweep_min_size</tt>
  # * <tt>:sweep_max_size</tt>
  # * <tt>:sweep_interval</tt>
  # * <tt>:pct_success</tt> - default is 99.
  #
  # Option examples:
  #   :protocol => 'ipv4'
  #   :count => 10
  #   :timeout => 1
  #   :size=> 512
  #   :protocol=> 'ipv4', :count=> 20, :size=> 1500, :timeout=>5
  #
  def ping(target_ip_address, arg={})

    pct_success = arg.delete(:pct_success) || 99

    if arg.empty?

      output = exec "ping #{target_ip_address}", arg

    else

      @matches = Set.new

      set_ping_base_matches target_ip_address, arg
      set_ping_extended_matches arg
      set_ping_sweep_matches arg

      output = exec "ping", arg

    end

    # r = output[0].find { |x| x =~/Success.*[^\d](\d+) percent \((\d+)\/(\d+)\)/}
    r = output.join  =~/Success.*[^\d](\d+) percent \((\d+)\/(\d+)\)/

    if r && 
      Regexp.last_match(1) && 
      Regexp.last_match(2) && 
      Regexp.last_match(3)
      
      pct = $1.to_i
      tx  = $3.to_i
      rx  = $2.to_i

      if $1.to_i < pct_success
        raise ::Expect4r::Router::Error::PingError.new(@host, target_ip_address, pct_success, pct, tx, rx, output)
      else
        [$1.to_i,[$2.to_i,$3.to_i],output]
      end

    else
      raise ::Expect4r::Router::Error::PingError.new(@host, target_ip_address, pct_success, pct, tx, rx, output)
    end

  end

private

  def set_ping_base_matches(target_ip_address, arg={})
    protocol          = arg[:protocol]      || ''
    repeat_count      = arg[:repeat_count]  || arg[:count] || ''
    datagram_size     = arg[:datagram_size] || arg[:size]  || ''
    timeout           = arg[:timeout]       || ''
    @matches << [/Protocol.+\: $/, protocol]
    @matches << [/Target IP address\: $/, target_ip_address]
    @matches << [/Repeat count.+\: $/, repeat_count]
    @matches << [/Datagram size.+\: $/, datagram_size]
    @matches << [/Timeout.+\: $/, timeout]
  end

  def set_ping_extended_matches(arg={})
    extended_keys = [:source_address, :tos, :df, :pattern]
    if (extended_keys & arg.keys).empty? and ! arg[:source_address]
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
      @matches << [/Sweep range of sizes.+: $/, 'no']
    else
      min_size = arg[:sweep_min_size] || ''
      max_size = arg[:sweep_max_size] || ''
      interval = arg[:sweep_interval] || ''
      @matches << [/Sweep range of sizes.+: $/, 'yes']
      @matches << [/Sweep min size.+\: $/, min_size]
      @matches << [/Sweep max size.+\: $/, max_size]
      @matches << [/Sweep interval.+\: $/, interval]
    end
  end

end
end

