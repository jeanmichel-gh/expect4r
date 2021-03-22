
module Expect4r
  class Base
    include Expect4r
    class << self
      attr_reader :routers
      def all
        @arr || []
      end
      def add(r)
        @arr ||=[]
        @arr << r
      end
    end
    def initialize(*args)
      @matches = Set.new
      Base.add(self)
      self
    end
  end
  
  class BaseLoginObject < Base
    class << self
      # Examples:
      #   my_mac = RShell.new_telnet '1.1.1.1', 'me', 'secret'
      #   ios = Ios.new_telnet '1.1.1.1', 'lab', 'lab'
      #   iox = Iox.new_telnet '1.1.1.1', 'username', 'pwd'
      #
      def new_telnet(*args)
        new :telnet, *args
      end
      # Examples:
      #   my_mac = RShell.new_ssh '1.1.1.1', 'me', 'secret'
      #   iox = Ios.new_ssh '1.1.1.1', 'lab', 'lab'
      #   ios = Iosx.new_ssh '1.1.1.1', 'username', 'pwd'
      #
      def new_ssh(*args)
        new :ssh, *args
      end
      attr_reader :routers
      def add(r)
        @routers ||=[]
        @routers << r
      end
    end
    attr_reader :host, :user, :method, :port, :proxy
    alias :username :user
    alias :hostname :host
    # Adds a login to a Expect4r::BaseLoginObject"
    #
    # Constructor: 
    # * <tt>new</tt>  <method>, <username>, <password>, <enable_password>, <port>
    # * <tt>new</tt>  <method>, <username>, <password>, <enable_password>
    # * <tt>new</tt>  <method>, <username>, <password>, <port>
    # * <tt>new</tt>  <method>, <username>, <password>
    #
    # * <tt>new</tt>  <method>, options={}
    #
    # Options are:  
    # * <tt>:host</tt> or <tt>:hostname</tt>
    # * <tt>:user</tt> or <tt>:username</tt>
    # * <tt>:pwd</tt> or <tt>:password</tt>
    # * <tt>:enable_password</tt>
    # * <tt>:port</tt>
    #
    # Examples:
    #
    #   new :telnet, :host=> '1.1.1.1', 
    #                :user=> 'lab', 
    #                :password=>'lab', 
    #                :enable_password=>'secret', 
    #                :port=>2001
    # 
    #   new :ssh, :host=> '1.1.1.1', :user=> 'jme'
    #   new :telnet, '1.1.1.1', 'jme', 'myPwd', 'myEnablePwd', 2001
    #
    #  
    
=begin rdoc

@method, host, @user, pwd, enable_pwd, port = args
@method, host, @user, pwd, enable_pwd       = args
@method, host, @user, pwd, port             = args
@method, host, @user, pwd                   = args

@method, host+port, @user, pwd, enable_pwd  = args
@method, host+port, @user, pwd              = args
  
=end
    
    def initialize(*args)
      host, _pwd, _enable_pwd, ciphered_password=[nil]*5
      if args.size>2 and args[1].is_a?(String)
        case args.size
        when 6
          @method, host, @user, _pwd, _enable_pwd, port = args
        when 5
          if args.last.is_a?(Integer)
            @method, host, @user, _pwd, port = args
          else
            @method, host, @user, _pwd, _enable_pwd = args
          end
        else
          @method, host, @user, _pwd, port = args
        end

        raise ArgumentError if host.split.size>1 and port
            
        @host, _port = host.split
        @port = port || (_port || 0).to_i

      elsif args.size == 2 and args[1].is_a?(Hash) and args[0].is_a?(Symbol)
        @method = args[0]
        @host = args[1][:host] || args[1][:hostname]
        port = args[1][:port]
        @port = (port || 0).to_i
        @user = args[1][:user]|| args[1][:username]

        _pwd  = args[1][:pwd]  || args[1][:password]
        ciphered_password  = args[1][:ciphered_password]

        _enable_pwd  = args[1][:enable_password]
        ciphered_enable_password  = args[1][:ciphered_enable_password]

      else
        raise
      end
      
      @pwd = if ciphered_password
        ciphered_password
      else
        Expect4r.cipher(_pwd) if _pwd
      end

      @enable_pwd = if ciphered_enable_password
        ciphered_enable_password
      else
          Expect4r.cipher(_enable_pwd || _pwd) if _enable_pwd || _pwd
      end
      
      @ps1 = /(.*)(>|#|\$)\s*$/
      @more = / --More-- /
      @matches=Set.new
      Base.add(self)
      self
    end

    attr_writer :host, :user, :port
    alias :hostname= :host=
    alias :username= :user=

    attr_accessor :ssh_options
    
    def method=(arg)
      case arg
      when :telnet, :ssh
        @method= arg
      else
        raise ArgumentError
      end
    end

    def spawnee
      case method
      when :telnet  ; "telnet #{host} #{port if port>0}"
      when :ssh
        cmd  ="ssh #{host}"
        cmd +=" -oPort=#{port}"             if port>0
        cmd +=" -oUser=#{spawnee_username}" if spawnee_username
        cmd += [" ", [ssh_options]].flatten.join(" ") if ssh_options
        cmd
      else
        raise RuntimeError
      end
    end

    def spawnee_username
      @user
    end

    def spawnee_prompt
      @ps1
    end

    def connect_retry
      @connect_retry ||= 0
    end

    def connect_retry=(arg)
      raise ArgumentError unless (0 .. 100_000) === arg
      @connect_retry = arg
    end
    
    def dup
      if @pwd
        self.class.new @method, @host, @user, Expect4r.decipher(@pwd)
      else
        self.class.new @method, @host, @user
      end
    end

    def password
      @pwd
    end

    def enable_password
      @enable_pwd
    end
    
    def cmp(o)
      o.spawnee == spawnee and o.password == password and o.enable_password == enable_password
    end      

    private

    def spawnee_password
      @pwd ||= Expect4r.cipher( ask("(#{self}) Enter your password:  ") { |q| q.echo = "X" } )
      Expect4r.decipher(password)
    end
    
    def spawnee_enable_password
        @enable_pwd ||= Expect4r.cipher( ask("(#{self}) Enter your enable password:  ") { |q| q.echo = "X" } )
      Expect4r.decipher(enable_password)
    end
    
    def spawnee_reset
      @pwd=nil
      @enable_pwd=nil
    end

  end
end

at_exit { 
  if Expect4r::Base.all
    Expect4r::Base.all.each { |o| o.logout if o.respond_to? :logout }
  end
}

