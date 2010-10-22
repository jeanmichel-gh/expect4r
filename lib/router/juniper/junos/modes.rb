require 'router/modes'

module Interact
module Router
module Junos
module Modes

def config(stmts=nil, arg={})
  login unless connected?
  if stmts
    mode = in?
    to_config
    output = send(stmts, arg)
    output << commit
    change_mode_to(mode)
    output
  else
    mode
  end
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
      to_exec
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

def set_cli_logical_router(logical_router)
  return if @ps1_bis
  to_exec
  arr= @lp.split(">")
  @ps1_bis = /#{arr[0]}:#{logical_router}(\#|>)\s*$/
  p @ps1_bis
  putline "set cli logical-router #{logical_router}"
end

def clear_cli_logical_router()
  return unless @ps1_bis
  to_exec
  @ps1_bis=nil
  putline "clear cli logical-router"
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
  return in? if @ps1_bis
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


__END__

Console prompts:

login:
user@router%
user@router>
user@router#
