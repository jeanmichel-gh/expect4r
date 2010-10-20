
require 'rubygems'
require 'highline/import'

module Interact
module Router
module Common

  def termserver?
    @port.to_i > 0
  end

  def io_escape_char_cb
    putc "\n" if termserver?
  end

  def spawnee
    case method
    when :telnet  ; "telnet #{host} #{port if port>0}"
    when :ssh     ; "ssh #{spawnee_username}@#{host}"
    else
      raise RuntimeError
    end
  end

  def show(s, arg={})
    exec "show #{s}", arg
  end
  def spawnee_username
    @user
  end

  def spawnee_password
    if @pwd==nil
      @pwd = Interact.cipher( ask("Enter your password:  ") { |q| q.echo = "X" } )
    else
      Interact.decipher(@pwd)
    end
  end

  def spawnee_prompt
    @prompt
  end

end
end
end