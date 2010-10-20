require 'router/modes'

module Interact
module Router
module Iox
module Modes

  def config(config=nil, arg={})
    login unless connected?
    mode = in?
    if config
      output = send(config, arg)
      output << commit
      change_mode_to mode
      output
    else
      change_mode_to :config
    end
  end

  def show_configuration_failed
    putline 'show configuration failed'
  end

  def commit(arg={})
    raise Iox::BogusCliMode unless config?
    output=''
    begin
      output = putline "commit", arg
    rescue Exception => e
      raise Iox::ConfigError
    end
    if /\% Failed to commit/.match(output.join)
      err = show_configuration_failed
      putline 'abort'
      raise Iox::ConfigError.new(err)
    end
    output
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

  def exec?
    ! shell? and ! config?
  end

  def shell?
    @lp == '# '
  end

  def _config_mode_
    return :config if config?
    to_exec
    putline 'configure'
    raise RuntimeError, "unable to got to config mode" unless config?
    :config
  end

  def _shell_mode_
    return :shell if shell?
    to_exec
    putline 'run'
    raise RuntimeError, "unable to got to shell mode" unless shell?
    :shell
  end

  def _exec_mode_
    return :exec if exec?
    putline "exit"  if shell?
    putline "abort" if config?
    raise RuntimeError, "unable to got to exec mode" unless exec?
    :exec
  end

  alias  to_config _config_mode_
  alias  to_shell  _shell_mode_
  alias  to_exec   _exec_mode_

end
end
end
end