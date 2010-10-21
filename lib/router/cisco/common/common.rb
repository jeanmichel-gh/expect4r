
module Interact
module Router
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
  
  def putline(line,*args)
    output, rc = super
    raise InvalidInputError.new(line) if output.join =~ /\% Invalid input detected at/
    output
  end
  
end
end
end