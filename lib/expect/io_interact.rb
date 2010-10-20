require 'thread'
require 'pty'

Thread.abort_on_exception=true

class IO
  def _io_save(no_echo=false, ch=nil)
    s = _io_string!
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

module Interact

  class NoChildError < RuntimeError
  end
  class SpawnError < RuntimeError
  end
  class InteractIO_Error < RuntimeError
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
      # STDOUT.puts "*** FALSE ***"
      @thread = Thread.new do
        PTY.spawn(cmd) do |pipe_read, pipe_write, pid|
          @r, @w, @pid = pipe_read, pipe_write, pid
          Process.wait(@pid,0)
          child_exited = true
        end
      end
      # STDOUT.puts "*** #{child_exited} ***"      
      while @r.nil? ; sleep(0.3) ; end unless  child_exited
      
    rescue => e
      raise SpawnError
    end
    
  end

  alias logout child_exit
  
  def flush
    @w.flush
  end
  
  def putc(c)
    return unless @w || c.nil?
    exp_internal "[#{c}]"
    @w.putc(c) and flush
  rescue Errno::EIO
    child_exit
    raise 
  end
  
  def puts(s)
    print "#{s}\n"
  end
  def print(s)
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
  def sync
    @r._io_sync
  end
  
  def connected?
    @r && (not child_exited?)
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
            # STDOUT.flush
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

  def interact(k=?\C-z)
    STDOUT.puts "\n\#\n\# #{ctrl_key k} to terminate.\n\#\n"
    reader :start
    writer k
  rescue
  ensure
    begin
      reader :terminate
      putline ' ', :no_trim=>true, :no_echo=>true
    rescue
      logout
    end
  end

  def putline(line, arg={})
    raise NoChildError if child_exited?
    arg = {:ti=>13, :no_echo=>false, :debug=>0, :sync=> true, :no_trim=>false}.merge(arg)
    no_echo = arg[:no_echo]
    ti = arg[:ti]
    line = line.gsub(/\s+/,' ').gsub(/^\s+/,'') unless arg[:no_trim]
    return [[], :empty_line] unless line.size>0
    sync if arg[:sync]
    puts line
    output=[]
    rc, buf = catch(:done) do
      @r.readbuf(arg[:ti]) do |r|
        if r._io_exit?
          r._io_save(no_echo)
          throw :done, [ :abort,  r._io_buf1]
        end
        case r._io_string
        when @prompt
          exp_internal "matching PROMPT "
          unless r._io_more?
            r._io_save(no_echo)
            exp_internal "returning #{r._io_buf1.inspect}"
            throw(:done, [:ok, r._io_buf1])
          end
          exp_internal "PROMPT WITH MORE"
        when /(.+)\r\n/
          exp_internal "matching EOL" 
          r._io_save(no_echo)
        when @more
          exp_internal "matching MORE" 
          r._io_save(no_echo)
          putc ' '
        end
      end
    end
    case rc
    when :abort
      exp_internal "putline abort: #{caller[0]}"
      raise InteractIO_Error
    else
      @lp = buf.last
    end
    [buf, rc]
  end

  def putlines(lines, arg={})
    r=[]
    lines.each_line do |l|
      l = l.chomp("\n").chomp("\r").strip
      r << putline(l, arg) if l.size>0
    end
    r.size==1 ? r.flatten : r
  end

  alias send putlines

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
    raise RuntimeError, buf if ev == :timeout
    [buf, ev]
  end

  def readline(ti=2)
    expect(/(.+)\r\n/, ti)
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
          throw :done, [ :timeout,  output]
        end
        case read_pipe._io_string
        when spawnee_prompt
          exp_internal "match PROMPT"
          read_pipe._io_save no_echo
          throw(:done, [:ok, output])
        when /(user\s*name\s*|login):\s*$/i
          exp_internal "match USERNAME"
          read_pipe._io_save no_echo
          puts spawnee_username
        when /password:\s*$/i
          exp_internal "match PASSWORD"
          read_pipe._io_save no_echo
          @w.print(spawnee_password+"\n") and flush
        when /Escape character is/
          exp_internal "match Escape char"
          read_pipe._io_save no_echo
          io_escape_char_cb
        when /.*\r\n/
          exp_internal "match EOL"
          read_pipe._io_save no_echo, "\r\n"
        end
      end
    end
    case ev
    when :timeout
      p "TIMEOUT/ERROR: #{(Time.now - t0)}"
      logout
      raise RuntimeError # for now....  
    else
      @lp = buf.last
    end
    [buf, ev]
    
  end
  
  private
 
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

