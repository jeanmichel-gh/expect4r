
module Expect4r::Router
module CiscoCommon
  
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
    
end
end

