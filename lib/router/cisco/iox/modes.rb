require 'router/modes'

module Expect4r::Router::Iox
module Modes

  # Adds an Iox <tt>config</tt> mixin.
  #
  # Options are:
  #
  # Option examples:
  #
  #   iox.config %{
  #      interface GigabitEthernet0/2/0/0
  #      desc to switch port 13'
  #      ipv4 address 190.0.0.9 255.255.255.252'
  #      no shut'
  #   }
  #
  def config(config=nil, arg={})
    login unless connected?
    if config
      mode = in?
      change_mode_to :config
      output = exp_send(config, arg)
      output << commit
      change_mode_to mode
      output
    else
      change_mode_to :config
    end
  end

  def exec(cmd=nil, arg={})
    login unless connected?
    if cmd.nil?
      change_mode_to :exec
    else
      if exec?
        output = exp_send(cmd, arg)
      elsif config?
        output = exp_send("do #{cmd}", arg)
      else
        mode = in?
        change_mode_to :exec
        output = exp_send(cmd, arg)
        change_mode_to mode
        output
      end
    end
  end

  def shell(cmd=nil, arg={})
    connected = connected?
    login unless connected?
    if cmd.nil?
      to_shell
    else
      if shell?
        output = exp_send(cmd, arg)        
      elsif config?
        output = exp_send("do run #{cmd}", arg)
      elsif exec?
        output = exp_send("run #{cmd}", arg)
      else
        raise RuntimeError # TODO
      end
      output
    end
  end

  def config?
    @lp =~ /\(config(|.+)\)/
  end
  
  def submode?
    return '' unless config?
     @lp =~ /\(config(|.+)\)/
     Regexp.last_match(1).split('-')[1..-1].join('-')
  end
  
  def exec?
    ! shell? and ! config?
  end

  def shell?
    @lp == '# '
  end

  def to_config
    return :config if config?
    to_exec
    putline 'configure'
    raise RuntimeError, "unable to get to config mode" unless config?
    :config
  end

  def to_shell
    return :shell if shell?
    to_exec
    putline 'run'
    raise RuntimeError, "unable to get to shell mode" unless shell?
    :shell
  end

  def to_exec
    return :exec if exec?
    putline "exit"  if shell?
    putline "abort" if config?
    raise RuntimeError, "unable to get to exec mode" unless exec?
    :exec
  end

end
end
