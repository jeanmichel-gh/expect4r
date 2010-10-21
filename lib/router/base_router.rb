module Interact
module Router
  class BaseRouter
    class << self
      def new_telnet(*args)
        new :telnet, *args
      end
      def new_ssh(*args)
        new :ssh, *args
      end
    end
    attr_reader :host, :user, :method, :port
    alias :username :user
    alias :hostname :host
    def initialize(*args)
      if args.size>2 and args[1].is_a?(String)
        @method, host, @user, pwd = args
      elsif args.size == 2 and args[1].is_a?(Hash) and args[0].is_a?(Symbol)
        @method = args[0]
        host = args[1][:host] || args[1][:hostname]
        @user = args[1][:user]|| args[1][:username]
        pwd  = args[1][:pwd]  || args[1][:password]
      end
      @host, port = host.split
      @port = port.to_i
      @pwd  = Interact.cipher(pwd) if pwd
      @ps1 = /(.*)(>|#|\$)\s*$/
      @more = / --More-- /
      @matches=[]
    end
  end
end
end
