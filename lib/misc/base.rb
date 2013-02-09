
module Expect4r
  class Base
    include Expect4r
    class << self
      attr_reader :routers
      def all
        @arr
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
    # * <tt>new</tt>  <method>, <username>, <password>, [port_number]
    # * <tt>new</tt>  <method>, options={}
    #
    # Options are:  
    # * <tt>:host</tt> or <tt>:hostname</tt>
    # * <tt>:user</tt> or <tt>:username</tt>
    # * <tt>:pwd</tt> or <tt>:password</tt>
    #
    # Examples:
    #   new :telnet, :host=> '1.1.1.1', :user=> 'lab', :password=>'lab'
    #   new :ssh, :host=> '1.1.1.1', :user=> 'jme'
    #   new :ssh, '1.1.1.1', 'me', 'secret'
    #
    def initialize(*args)
      ciphered_password=nil
      if args.size>2 and args[1].is_a?(String)
        @method, host, @user, pwd = args
        @host, port = host.split
        @port = (port || 0).to_i
      elsif args.size == 2 and args[1].is_a?(Hash) and args[0].is_a?(Symbol)
        @method = args[0]
        @host = args[1][:host] || args[1][:hostname]
        port = args[1][:port]
        @port = (port || 0).to_i
        @user = args[1][:user]|| args[1][:username]
        pwd  = args[1][:pwd]  || args[1][:password]
        ciphered_password  = args[1][:ciphered_password]
      else
        raise
      end
      @pwd = if ciphered_password
        ciphered_password
      else
        Expect4r.cipher(pwd) if pwd
      end
      @ps1 = /(.*)(>|#|\$)\s*$/
      @more = / --More-- /
      @matches=Set.new
      Base.add(self)
      self
    end

    attr_writer :host, :username, :port
    
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
      when :ssh     ; "ssh #{spawnee_username}@#{host} #{port if port>0}"
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
    
    def dup
      if @pwd
        self.class.new @method, @host, @user, Expect4r.decipher(@pwd)
      else
        self.class.new @method, @host, @user
      end
    end

    private

    def spawnee_password
      if @pwd.nil?
        @pwd = Expect4r.cipher( ask("(#{self}) Enter your password:  ") { |q| q.echo = "X" } )
        @asked4pwd=true
      end
      Expect4r.decipher(@pwd)
    end
    
    def spawnee_reset
      @pwd=nil if @asked4pwd
    end

  end
end

if __FILE__ != $0

  at_exit { 
    if Expect4r::Base.all
      Expect4r::Base.all.each { |o| o.logout if o.respond_to? :logout }
    end
  }

else

  require "test/unit"

  class Expect4r::Base
    def initialize
      Expect4r::Base.add(self)
    end
  end

  class Base < Test::Unit::TestCase
    include Expect4r

    def test_add
      assert [], Base.all
      Base.new
      assert 1, Base.all.size
      Base.new 
      assert_equal 2, Base.all.size
    end
  end

end
