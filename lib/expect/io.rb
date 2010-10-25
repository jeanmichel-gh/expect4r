require 'thread'
require 'pty'
require 'set'

Thread.abort_on_exception=true

class IO
  def _io_save(no_echo=false, match_string=nil, ch=nil)
    s = _io_string!
    exp_internal match_string
    exp_internal s
    return if no_echo
    s = s.chomp(ch) if ch
    _io_buf1 << s unless no_echo
  end
  def _io_more?   ; ! IO.select([self],nil,nil,0.20).nil? ; end
  def _io_exit?   ; _io_buf0.last.nil?                    ; end
  def _io_buf0    ; @_buf0_                               ; end
  def _io_buf1    ; @_buf1_                               ; end
  def _io_string  ; @_buf0_.join                          ; end
  def _io_string!
    b = _io_string
    @_buf0_=[]
    b
  end
  def _io_sync
    @_buf0_ ||=[]
    while _io_more?
      break if _io_read_char.nil?
    end
  end
  def _io_read_char
    c = getc
    @_buf0_ << c.chr unless c.nil?
    exp_internal "buf0: [#{_io_string.gsub(/\n/,'\n').gsub(/\r/,'\r')}]"
    c
  end
  def readbuf(ti=10)
    @_buf0_, @_buf1_=[],[]
    loop do
      if IO.select([self],nil,nil,ti).nil?
        exp_internal "IO.select is NIL (TIMEOUT=#{ti})"
        @_buf0_ << nil
      else
        _io_read_char
      end
      yield(self)
    end
  end
end

module Expect4r

  class ConnectionError < RuntimeError
    def initialize(*args)
      @output = args[0]
    end
    def err_msg
      "Connection Error: #{@output}"
    end
  end

  class ExpTimeoutError < RuntimeError
    def initialize(*args)
      @output, @timeout = args
    end
    def err_msg
      "Timeout Error: timeout= #{@timeout}: #{@output}"
    end
  end

  class SpawnError < RuntimeError
    def initialize(*args)
      @cmd = args[0]
    end
    def err_msg
      "Spawn Error: #{@cmd}"
    end
  end
  class Expect4rIO_Error < RuntimeError
  end

  def child_exit
    if @pid
      Process.kill(:KILL, @pid)
      @thread.kill
      @lp, @r, @w, @pid = [nil]*4
    end
  rescue Errno::ESRCH, Errno::ECHILD => e
  ensure
    @lp, @r, @w, @pid = [nil]*4
  end
  
  def spawn(cmd)
    begin
      child_exited = false
      @thread = Thread.new do
        PTY.spawn(cmd) do |pipe_read, pipe_write, pid|
          @r, @w, @pid = pipe_read, pipe_write, pid
          begin 
            Process.wait(@pid,0)
          rescue
          ensure
            child_exited = true
          end
        end
      end
      @thread.priority = -2
      unless child_exited
        while @r.nil?
          sleep(0.05) 
        end
      end
    rescue => e
      raise SpawnError.new(cmd)
    end
  end
  
  def logout
    child_exit
    @pid
  end
  
  def putc(c)
    return unless @w || c.nil?
    exp_internal "[#{c}]"
    @w.putc(c) and flush
  rescue Errno::EIO
    child_exit
    raise 
  end
  
  def exp_puts(s)
    exp_print "#{s}\r"
  end
  def exp_print(s)
    exp_internal "print: #{s.inspect}, io_writer: #{@w}"
    return unless @w
    @w.print(s) and flush
  rescue Errno::EIO, Errno::ECHILD
    child_exit
    raise
  end
  def getc
    @r.getc if @r
  rescue Errno::EIO, Errno::ECHILD
    child_exit
    raise
  end

  def interact(k=?\C-z)
    STDOUT.puts "\n\#\n\# #{ctrl_key k} to terminate.\n\#\n"
    reader :start
    writer k
  rescue
  ensure
    begin
      reader :terminate
      putline ' ', :no_trim=>true, :no_echo=>true
    rescue => e
      exp_internal e.to_s
    end
  end
  
  def putcr
    putline '', :no_trim=>true, :no_echo=>true
    nil
  end
  
  def exp_send(lines, arg={})
    r=[]
    lines.each_line do |l|
      l = l.chomp("\n").chomp("\r").strip
      r << putline(l, arg) if l.size>0
    end
    lines.size==1 ? r[0] : r
  end
  
  def expect(match, ti=5)
    ev, buf = catch(:done) do
      @r.readbuf(ti) do |r|
        if r._io_exit?
          throw :done, [ :timeout, r._io_string!]
        end
        case r._io_string
        when match
          throw :done, [:ok, r._io_string!.chomp("\r\n")]
        end
      end
    end
    exp_internal "#{ev.inspect} buf: #{buf.inspect}"
    raise ExpTimeoutError.new(buf, ti) if ev == :timeout
    [buf, ev]
  end

  def readline(ti=2)
    expect(/(.+)\r\n/, ti)
  end

  def connected?
    @r && (not child_exited?)
  end

  def login(c, o={})
    return if connected?

    spawn c

    o={:timeout=>13, :no_echo=>false}.merge(o)
    timeout =   o[:timeout]
    no_echo = o[:no_echo]

    output=[]
    t0 = Time.now
    ev, buf = catch(:done) do
      @r.readbuf(timeout) do |read_pipe|
        if read_pipe._io_exit?
          exp_internal "readbuf: _io_exit?"
          throw :done, [ :abort,  output]
        end
        case read_pipe._io_string
        when spawnee_prompt
          read_pipe._io_save false, "match PROMPT"
          throw(:done, [:ok, output])
        when /(user\s*name\s*|login):\r*$/i
          read_pipe._io_save no_echo, "match USERNAME"
          exp_puts spawnee_username
        when /password:\s*$/i
          read_pipe._io_save no_echo, "match PASSWORD"
          @w.print(spawnee_password+"\r") and flush
        when /Escape character is/
          read_pipe._io_save no_echo, "match Escape char"
          io_escape_char_cb
        when /.*\r\n/
          exp_internal "match EOL"
          read_pipe._io_save no_echo, "match EOL", "\r\n"
        end
      end
    end
    case ev
    when :abort
      elapsed = Time.now - t0
      if elapsed < timeout
        child_exit
        raise ConnectionError.new(c)
      else
        raise ExpTimeoutError.new(c, timeout)
      end
    else
      @lp = buf.last
    end
    [buf, ev]
    
  end
  
  private
 
  #FIXME ? putline to send_cmd ? 
  # hide putline and expose cmd
  def putline(line, arg={})
    raise ConnectionError.new(line) if child_exited?
    
    arg = {:ti=>13, :no_echo=>false, :debug=>0, :sync=> false, :no_trim=>false}.merge(arg)
    no_echo = arg[:no_echo]
    ti = arg[:ti]
    unless arg[:no_trim]
      line = line.gsub(/\s+/,' ').gsub(/^\s+/,'') unless arg[:no_trim]
      return [[], :empty_line] unless line.size>0
    end
    sync if arg[:sync]
    t0 = Time.now
    exp_puts line
    output=[]
    rc, buf = catch(:done) do
      @r.readbuf(arg[:ti]) do |r|
        if r._io_exit?
          r._io_save(no_echo)
          throw :done, [ :abort,  r._io_buf1]
        end
        case r._io_string
        when @ps1, @ps1_bis
          unless r._io_more?
            r._io_save false, "matching PROMPT"
            throw(:done, [:ok, r._io_buf1])
          end
          exp_internal "more..."
        when /(.+)\r\n/, "\r\n"
          r._io_save no_echo, "matching EOL", "\r\n"
        when @more
          r._io_save no_echo, "matching MORE"
          putc ' '
        end
        
        @matches.each { |match, _send|  
          if r._io_string =~ match
             r._io_save no_echo, "match #{match}"
            exp_puts _send
          end
        }
        
      end
    end
    case rc
    when :abort
      elapsed = Time.now - t0
      if elapsed < ti
        child_exit
        raise ConnectionError.new(line)
      else
        raise ExpTimeoutError.new(line, elapsed)
      end
    else
      @lp = buf.last
    end
    [buf, rc]
  end
  def ctrl_key(k)
    case k
    when ?\C-c ; '^C'
    when ?\C-q ; '^Q'
    when ?\C-z ; '^Z'
    end
  end

  def writer(k)
    stty_raw
    begin
      loop do
        break if (c = STDIN.getc) == k
        putc(c)
      end
    rescue PTY::ChildExited => e
      child_exit
    ensure
      stty_cooked
    end
  end

  def reader(arg=:start)
    case arg
    when :start
      stty_raw
      @reader = Thread.new do
        begin
          loop do 
            c = getc
            break if c.nil?
            STDOUT.putc c
          end
        rescue => e
          p e
          p '7777777'
        ensure
          stty_cooked
        end
      end
    when :terminate
      @reader.terminate if @reader
      stty_cooked
    end
  end
  
  def sync
    @r._io_sync
  end
  
  def child_exited?
    @pid == nil
  end

  def stty_cooked
    system "stty echo -raw"
  end

  def stty_raw
    system "stty -echo raw"
  end

  def flush
    @w.flush
  end
 
end

module Kernel
  def exp_debug(state=:enable)
    case state
    when :disable, :off
      Kernel.instance_eval {
        define_method("exp_internal") do |s|
        end
      }
      :disable
    when :enable, :on
      Kernel.instance_eval {
        define_method("exp_internal") do |s|
          STDOUT.print "\ndebug: #{s}"
        end
      }
      :enable
    else
      nil
    end
  end
  exp_debug :disable
end

module Expect4r
  class BaseObject
    class << self
      def new_telnet(*args)
        new :telnet, *args
      end
      def new_ssh(*args)
        new :ssh, *args
      end
      attr_reader :routers
      def add(r)
        @routers ||=[]
        @routers << r
      end
    end
    attr_reader :host, :user, :method, :port
    alias :username :user
    alias :hostname :host
    def initialize(*args)
      ciphered_pwd=nil
      if args.size>2 and args[1].is_a?(String)
        @method, host, @user, pwd = args
      elsif args.size == 2 and args[1].is_a?(Hash) and args[0].is_a?(Symbol)
        @method = args[0]
        host = args[1][:host] || args[1][:hostname]
        @user = args[1][:user]|| args[1][:username]
        pwd  = args[1][:pwd]  || args[1][:password]
        ciphered_pwd  = args[1][:ciphered_pwd]
      end
      @host, port = host.split
      @port = port.to_i
      @pwd = if ciphered_pwd
        ciphered_pwd
      else
        Expect4r.cipher(pwd) if pwd
      end
      @ps1 = /(.*)(>|#|\$)\s*$/
      @more = / --More-- /
      @matches=Set.new
      BaseObject.add(self)
      self
    end
  end
end

if __FILE__ != $0

  at_exit { 
    if Expect4r::BaseObject.routers
      Expect4r::BaseObject.routers.each { |r| r.logout if r.respond_to? :logout }
    end
  }
  
else

  require "test/unit"

  class Expect4r::BaseObject
    def initialize
      Expect4r::BaseObject.add(self)
    end
  end

  class TestRouterBaseObject < Test::Unit::TestCase
    include Expect4r

    def test_add
      assert [], BaseObject.routers
      BaseObject.new
      assert 1, BaseObject.routers.size
      BaseObject.new 
      assert_equal 2, BaseObject.routers.size
    end
  end

end
