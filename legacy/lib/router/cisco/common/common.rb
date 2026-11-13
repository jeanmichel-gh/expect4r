
module Expect4r::Router
module CiscoCommon
  
  #
  # Returns the config level depths:
  #
  #  Example:
  #
  #    iox(config-ospf-ar)#
  #
  #    irb> iox.config_lvl?
  #    => 3
  # 
  def config_lvl?
    return -1 unless config?
    @lp =~ /\(config(|.+)\)/
    lvl = Regexp.last_match(1).split('-').size
    lvl == 0 ? 1 : lvl
  end
  
  def top
    return unless config?
    1.upto(config_lvl? - 1) { putline 'exit'}
  end
  
  def top?
    return false unless config?
    @lp =~ /\(config(|.+)\)/
    Regexp.last_match(1).size == 0
  end

  def method_missing(name, *args, &block)
    if name.to_s =~ /^show_/
      cmd = name.to_s.split('_').join(' ') + args.join(' ')
      cmd.gsub!(/running config/, 'running-config')
      output = __send__ :exec, cmd, *args
    elsif name.to_s =~ /^shell_/
      cmd = name.to_s.split('_')[1..-1].join(' ') + args.join(' ')
      output = __send__ :shell, cmd, *args
    else
      super
    end
  end
  
  def enable
    proc = Proc.new {
      puts "FOUND WE HAVE A BAD PASSWORD SITUATION"
    }
    @pre_matches ||= []
    @pre_matches << [/Bad Password/i, proc]

    enable_pwd = [/^Password: $/, spawnee_enable_password]
    @matches << enable_pwd
    exp_send 'enable'
    @matches =[]
    @pre_matches=[]
    exec "term len 0\nterm width 0"
  rescue 
    raise
  ensure
    @matches.delete enable_pwd
  end
    
  def login(arg={})
    # Skip the default banner.
    proc = Proc.new {
      read_until /QUICK START GUIDE/, 2
    }
    @pre_matches = []
    @pre_matches << [/Cisco Configuration Professional/, proc]
    
    super(spawnee,arg)
    enable unless arg[:no_enable]

    self
  end
  # FIXME: 1.9.2 bug: 
  # It calls LoginBaseOject#login() instead of calling J#login()
  # modified login_by_proxy to call _login_ seems to work.
  alias :_login_ :login
    
end
end

