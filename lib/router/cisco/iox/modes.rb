require 'router/modes'

module Interact
module Router
module Iox
module Modes

  def config(config=nil, arg={})
    login unless connected?
    if config
      mode = in?
      change_mode_to :config
      output = send(config, arg)
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
        output = send(cmd, arg)
      elsif config?
        output = send("do #{cmd}", arg)
      else
        mode = in?
        change_mode_to :exec
        output = send(cmd, arg)
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
        output = send(cmd, arg)        
      elsif config?
        output = send("do run #{cmd}", arg)
      elsif exec?
        output = send("run #{cmd}", arg)
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
    raise RuntimeError, "unable to got to config mode" unless config?
    :config
  end

  def to_shell
    return :shell if shell?
    to_exec
    putline 'run'
    raise RuntimeError, "unable to got to shell mode" unless shell?
    :shell
  end

  def to_exec
    return :exec if exec?
    putline "exit"  if shell?
    putline "abort" if config?
    raise RuntimeError, "unable to got to exec mode" unless exec?
    :exec
  end

end
end
end
end