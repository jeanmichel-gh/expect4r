require 'router/router_modes'
module IosModes
  
  def in?(mode=:none)
    login unless connected?
    case mode
    when :enable  ; enable?
    when :user    ; user?
    when :config  ; config?
    else
      _mode_?
    end
  end
  
  def _mode_?
     if user? 
       :user
     elsif config?
       :config
     elsif enable?
       :enable
     end
   end
   
  def config?
    @lp =~ /\(config(|.+)\)/
  end
  
  def enable?
    ! user? and ! config?
  end
  
  def user?
    @lp =~ /.+>\s*$/
  end
    
  def _config_mode_
    return :config if config?
    to_enable
    putline 'configure terminal'
    raise RuntimeError, "unable to got to config mode" unless config?
    :config
  end
  
  def _enable_mode_
    return :enable if enable?
    exp_debug :enable
    if user?
      puts 'enable'
      expect 'Password'
      putline 'lab'
    elsif config?
      putline 'exit'
    end
    raise RuntimeError, "unable to got to enable mode" unless enable?
    :enable
  end
  
  def _user_mode_
    return if user?
    putline "exit"
    raise RuntimeError, "unable to got to user mode" unless exec?
    :user
  end
  
  alias  to_config  _config_mode_
  alias  to_enable  _enable_mode_
  alias  to_user    _user_mode_
  
end
