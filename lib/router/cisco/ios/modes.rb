require 'router/modes'

module Expect4r::Router::Ios
module Modes
  
  # Adds a <tt>in?</tt> mixin.
  #
  # Returns the mode the router is in:  :user, :exec, :config
  #
  def in?(mode=:none)
    login unless connected?
    case mode
    when :exec    ; exec?
    when :user    ; user?
    when :config  ; config?
    else
      _mode_?
    end
  end
  
  
  def config(config=nil, arg={})
    login unless connected?
    if config
      mode = in?
      change_mode_to :config
      output = exp_send(config, arg)
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
  
  def _mode_?
     if user? 
       :user
     elsif config?
       :config
     elsif exec?
       :exec
     end
   end
   
  def config?
    @lp =~ /\(config(|.+)\)/
  end
  
  #
  # returns *true* if router is in <tt>:exec</tt> (enabled) mode,  *false* otherwise.
  #
  def exec?
    ! user? and ! config?
  end
  
  #
  # returns *true* if router is in <tt>:user</tt> mode,  *false* otherwise.
  #
  def user?
    @lp =~ /.+>\s*$/
  end
    
  def to_config
    return :config if config?
    to_exec
    putline 'configure terminal' if exec?
    raise RuntimeError, "unable to get to config mode" unless config?
    :config
  end
  
  def to_exec
    return :exec if exec?
    if config?
      1.upto(config_lvl?) { putline 'exit'}
    end
    raise RuntimeError, "unable to get to exec mode" unless exec?
    :exec
  end

  def to_user
    return if user?
    putline "exit"
    raise RuntimeError, "unable to get to user mode" unless exec?
    :user
  end
  
end
end
