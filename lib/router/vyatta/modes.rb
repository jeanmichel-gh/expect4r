require 'router/modes'

module Expect4r::Router::Vyatta
module Modes

# Adds a Vyatta <tt>config</tt> mixin.
#
# Example:
#
#  c.config %{
#    edit protocols bgp 100
#      set neighbor 192.168.129.1
#      set neighbor 192.168.129.1 capability orf prefix-list receive
#      set neighbor 192.168.129.1 ebgp-multihop 10
#      set neighbor 192.168.129.1 remote-as 200
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

# Adds a Vyatta <tt>exec</tt> mixin.
#
# Example:
#
#   v.exec 'set cli screen-length 0'
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

def exec?
  
  @lp =~ /\$ $/ ? true : false
end

def config?
  if logged_as_root?
  else
    @lp =~ /^.+# $/ ? true : false
  end
end

def in?(mode=:none)
  login unless connected?
  case mode
  when :exec    ; exec?
  when :config  ; config?
  else
    _mode_?
  end
end

def to_config
  return :config if config?
  to_exec
  putline 'configure', :debug=>1
  raise RuntimeError, "unable to get to config mode" unless config?
  :config
end

def to_exec
  return :exec if exec?
  top if config?
  exit
  raise RuntimeError, "unable to get to exec mode" unless exec?
  :exec
end

def change_mode_to(mode)
  login unless connected?
  case mode
  when :exec    ;  to_exec
  when :config  ;  to_config
  end
end

private

def logged_as_root?
  ! (@_is_root_ ||=  @lp =~ /root@/).nil?
end

def _mode_?
  putline ' ', :no_trim=>true, :no_echo=>true unless @lp
  if exec? 
    :exec
  elsif config?
    :config
  else
  end
end

end
end
