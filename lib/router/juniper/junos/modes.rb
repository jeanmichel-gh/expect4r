require 'router/modes'

module Interact
module Router
module Junos
module Modes
  
  def config(config=nil, arg={})
    login unless connected?
    mode = in?
    mode = change_mode_to :config
    if config
      output = send(config, arg)
      output << commit
      change_mode_to(mode)
      output
    else
      mode
    end
  end
  
  def commit(arg={})
    raise BogusCliMode unless config?
    output=''
    begin
      output = putline "commit", arg
    rescue Exception => e
      raise ConfigError
    end
    if /\% Failed to commit/.match(output.join)
      putline 'rollback'
      raise ConfigError.new(output)
    end
    output
  end
  
  def exec(cmd=nil, *args)
    login unless connected?
    if cmd.nil?
      to_exec
    else
      if config?
        send("run #{cmd}", *args)
      elsif exec?
        send cmd, *args
      else
        mode = _mode_?
        change_mode_to :exec
        output = send(cmd, *args)
        change_mode_to mode
        output
      end
    end
  end
  
  def shell(cmd=nil, *args)
    connected = connected?
    login unless connected?
    if cmd.nil?
      to_shell
    else
      mode = _mode_?
      to_shell
      output = send(cmd, *args)
      change_mode_to mode
      output
    end
  end
  
  def exec?
    @lp =~ /> $/ ? true : false
  end
  
  def config?
    @lp =~ /^.+# $/ ? true : false
  end
  
  def shell?
    @lp == '% ' ? true : false
  end
  
  private
 
  def to_config
    return :config if config?
    to_exec
    putline 'edit', :debug=>1
    raise RuntimeError, "unable to got to config mode" unless config?
    :config
  end
  
  def to_shell
    return :shell if shell?
    to_exec
    putline 'start shell'
    raise RuntimeError, "unable to got to shell mode" unless shell?
    :shell
  end
  
  def to_exec
    return :exec if exec?
    top if config?
    exit
    raise RuntimeError, "unable to got to exec mode" unless exec?
    :exec
  end

end
end
end
end
