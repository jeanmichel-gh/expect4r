# frozen_string_literal: true
# Independent terminal program: never imports production parsers or drivers.
require 'io/console'
require 'shellwords'
$stdout.sync = true
$stdin.raw! if $stdin.tty?
class RouterCLI
  def initialize(args)
    @adapter = args.find { |a| a.start_with?('--adapter=') }&.split('=', 2)&.last || 'ios'
    @scenario = args.find { |a| a.start_with?('--scenario=') }&.split('=', 2)&.last || 'normal'
    @fragment = args.include?('--fragment')
    @mode, @pending, @running, @path, @edit_history = :exec, [], [], [], []
    @privileged = @scenario != 'user_mode'
  end
  def emit(text)
    if @fragment
      text.bytes.each { |byte| $stdout.write(byte.chr); sleep 0.0002 }
    else
      $stdout.write(text)
    end
  end
  def prompt
    return @mode == :config ? 'lab@router# ' : 'lab@router> ' if @adapter == 'junos'
    return @privileged ? 'router#' : 'router>' unless @mode == :config
    submode = case @path.last
              when nil then 'config'
              when /\Aaddress-family/ then @adapter == 'iox' ? 'config-bgp-af' : 'config-router-af'
              when /\Arouter / then @adapter == 'iox' ? 'config-bgp' : 'config-router'
              when /\Ainterface range / then 'config-if-range'
              when /\Ainterface / then 'config-if'
              when /\Aline / then 'config-line'
              else 'config-unfamiliar-context'
              end
    "router(#{submode})#"
  end
  def emit_prompt
    emit("[edit#{@path.empty? ? '' : ' ' + @path.join(' ')}]\r\n") if @adapter == 'junos' && @mode == :config
    emit(prompt)
  end
  def read_line(interactive: false)
    line = ''.b
    loop do
      char = $stdin.getc
      return nil unless char
      if char == "\x03" && interactive
        line.clear
        emit("\r\n")
        emit_prompt
      elsif char == "\r" || char == "\n"
        return line
      else
        line << char
      end
    end
  end
  def ask(question, default = '')
    emit(question)
    answer = read_line
    raise EOFError unless answer
    emit("#{answer}\r\n")
    answer.empty? ? default : answer
  end
  def run
    if @scenario == 'host_key'
      emit("Host key verification failed.\r\n")
      return
    end
    emit("Welcome to the independent CLI simulator\r\nUsername: ")
    username = read_line
    emit("#{username}\r\nPassword: ")
    password = read_line
    unless username == 'lab' && password == 'secret'
      emit("\r\nAuthentication failed\r\n")
      return
    end
    emit("\r\n")
    emit_prompt
    while (command = read_line(interactive: true))
      emit("#{command}\r\n")
      operational = command.sub(/\A(?:do|run) /, '')
      break if execute(command, operational) == :disconnect
      emit_prompt
    end
  rescue EOFError
    nil
  end
  def execute(command, operational)
    case operational
    when ''
    when 'terminal length 0', 'set cli screen-length 0'
    when 'show version'
      emit("Simulator #{@adapter}\r\n  quoted spaces stay   here\r\n\r\nBuild 42\r\n")
    when 'show paged'
      3.times do |page|
        emit("page #{page + 1}\r\n")
        if page < 2
          emit(' --More-- ')
          return :disconnect unless $stdin.getc == ' '
        end
      end
    when 'show running-config', 'show configuration'
      emit(@running.join("\r\n") + "\r\n")
    when 'show large'
      1000.times { |i| emit("line #{i}\r\n") }
    when 'show slow'
      emit("partial output\r\n")
      sleep 0.25
    when 'show disconnect'
      emit('partial output')
      return :disconnect
    when /\Aping(?: |$)/
      return ping(operational)
    when 'enable'
      emit('Password: ')
      secret = read_line
      emit("\r\n")
      secret == 'enable-secret' ? @privileged = true : emit("% Bad password\r\n")
    when 'disable'
      @privileged = false
    when 'configure terminal', 'configure exclusive'
      if @scenario == 'locked'
        emit("error: configuration database locked\r\n")
      elsif @adapter != 'junos' && !@privileged
        emit("% Invalid input detected at '^' marker.\r\n")
      else
        @mode, @path = :config, []
      end
    when 'commit'
      if @scenario == 'commit_failure'
        emit("error: configuration check-out failed\r\n")
      else
        @running.concat(@pending)
        @pending.clear
        emit("commit complete\r\n")
      end
    when 'rollback 0', 'abort'
      @pending.clear
      @mode = :exec if command == 'abort'
    when 'end'
      @mode, @path = :exec, []
    when 'top'
      @path.clear
    when /\Aup(?: (\d+))?\z/
      [(@path.size), ($1 || 1).to_i].min.times { @path.pop }
    when /\Aedit (.+)\z/
      @edit_history << @path.dup
      tokens = Shellwords.shellsplit($1)
      until tokens.empty?
        keyword = tokens.shift
        @path << if %w[group unit family address neighbor area].include?(keyword) && !tokens.empty?
                   "#{keyword} #{tokens.shift}"
                 else
                   keyword
                 end
      end
    when 'exit', 'exit-address-family'
      if @mode != :config
        return :disconnect
      elsif @path.empty?
        @mode = :exec
      elsif @adapter == 'junos' && command == 'exit'
        @path = @edit_history.pop || []
      else
        @path.pop
      end
    when /\A(?:interface|router|line) .+\z/
      @path = [command]
    when /\Aaddress-family .+\z/
      @path = [@path.first, command]
    when 'mystery-context'
      @path << 'mystery-context'
    when 'bad command'
      emit(@adapter == 'ios' ? "% Invalid input detected at '^' marker.\r\n" : "error: syntax error\r\n")
    else
      if @mode == :config
        @adapter == 'ios' ? @running << command : @pending << command
      else
        emit("% Invalid input detected at '^' marker.\r\n")
      end
    end
    nil
  end
  def ping(command)
    count = 5
    if command == 'ping'
      family = @adapter == 'ios' ? 'ip' : 'ipv4'
      protocol = ask("Protocol [#{family}]: ", family)
      unless [family, 'ipv6'].include?(protocol)
        emit("% Invalid protocol\r\n")
        return
      end
      ask('Target IP address: ')
      count = Integer(ask('Repeat count [5]: ', '5'))
      ask('Datagram size [100]: ', '100')
      ask('Timeout in seconds [2]: ', '2')
      extended = ask(@adapter == 'ios' ? 'Extended commands [n]: ' : 'Extended commands? [no]: ', 'no')
      if extended =~ /\Ay/i
        ask('Source address or interface: ')
        ask('Type of service [0]: ')
        ask('Set DF bit in IP header? [no]: ')
        ask('Validate reply data? [no]: ')
        ask('Data pattern [0xABCD]: ')
        ask('Loose, Strict, Record, Timestamp, Verbose[none]: ')
      end
      sweep = ask(@adapter == 'ios' ? 'Sweep range of sizes [n]: ' : 'Sweep range of sizes? [no]: ', 'no')
      if sweep =~ /\Ay/i
        minimum = Integer(ask('Sweep min size [36]: ', '36'))
        maximum = Integer(ask('Sweep max size [18024]: ', '18024'))
        step = Integer(ask('Sweep interval [1]: ', '1'))
        count *= ((maximum - minimum) / step) + 1
      end
    elsif @adapter == 'junos'
      words = command.split
      index = words.index('count')
      count = Integer(words[index + 1]) if index
    end
    if @scenario == 'ping_timeout'
      emit("ping in progress\r\n")
      sleep 0.25
      return
    elsif @scenario == 'ping_disconnect'
      emit('ping interrupted')
      return :disconnect
    elsif @scenario == 'ping_malformed'
      emit("unrecognized ping statistics\r\n")
      return
    end
    received = case @scenario
               when 'ping_loss' then count * 3 / 5
               when 'ping_none' then 0
               else count
               end
    if @adapter == 'junos'
      loss = 100.0 * (count - received) / count
      emit("#{count} packets transmitted, #{received} packets received, #{loss}% packet loss\r\n")
      emit("round-trip min/avg/max/stddev = 1.5/2.5/4.5/0.75 ms\r\n") if received.positive?
    else
      emit("Type escape sequence to abort.\r\n")
      emit("Success rate is #{100 * received / count} percent (#{received}/#{count})")
      emit(', round-trip min/avg/max = 1/2/4 ms') if received.positive?
      emit("\r\n")
    end
    nil
  end
end
RouterCLI.new(ARGV).run
