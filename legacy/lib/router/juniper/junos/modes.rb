require 'router/modes'

module Expect4r::Router::Junos
module Modes

# Adds a Junos <tt>config</tt> mixin.
#
# Example:
#
#  j.config %{
#    edit logical-router Orleans protocols bgp
#      edit group session-to-200
#        set type external
#        set peer-as 200
#        set neighbor 40.0.2.1 peer-as 200
#  }
#
def config(stmts=nil, arg={})
  login unless connected?
  if stmts
    mode = in?
    to_config
    output = exp_send(stmts, arg)
    output << commit
    change_mode_to(mode)
    output.flatten
  else
    to_config
  end
end

# Adds a Junos <tt>exec</tt> mixin.
#
# Example:
#
#   j.exec 'set cli screen-length 0'
#
def exec(cmd=nil, *args)
  login unless connected?
  if cmd.nil?
    to_exec
  else
    if config?
      exp_send("run #{cmd}", *args)
    elsif exec?
      exp_send cmd, *args
    else
      mode = _mode_?
      to_exec
      output = exp_send(cmd, *args)
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
    output = exp_send(cmd, *args)
    change_mode_to mode
    output
  end
end

#
# returns *true* if router is in <tt>:exec</tt> mode,  *false* otherwise.
#
def exec?
  @lp =~ /> $/ ? true : false
end

#
# returns *true* if router is in <tt>:config</tt> mode, *false* otherwise.
#
def config?
  @lp =~ /^.+# $/ ? true : false
end

#
# returns *true* if router is in <tt>:shell</tt> mode, *false* otherwise.
#
def shell?
  if @lp == '% '
    true
  elsif logged_as_root? and @lp =~ /root@.+% $/
    true
  else
    false
  end
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
  raise RuntimeError, "unable to get to config mode" unless config?
  :config
end

def to_shell
  return in? if @ps1_bis
  return :shell if shell? 
  to_exec
  putline 'start shell'
  raise RuntimeError, "unable to get to shell mode" unless shell?
  :shell
end

def logged_as_root?
  ! (@_is_root_ ||=  @lp =~ /root@/).nil?
end

def to_exec
  return :exec if exec?
  top if config?
  logged_as_root? ? cli : exit
  raise RuntimeError, "unable to get to exec mode" unless exec?
  :exec
end

end
end
