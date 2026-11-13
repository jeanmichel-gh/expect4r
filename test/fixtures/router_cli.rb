# frozen_string_literal: true
# An independent terminal program. It intentionally never requires expect4r.
require 'io/console'
$stdout.sync = true
$stdin.raw! if $stdin.tty?

class RouterCLI
  def initialize(args)
    @adapter = args.find { |a| a.start_with?('--adapter=') }&.split('=', 2)&.last || 'ios'
    @scenario = args.find { |a| a.start_with?('--scenario=') }&.split('=', 2)&.last || 'normal'
    @fragment = args.include?('--fragment')
    @mode, @pending, @running = :exec, [], []
  end
  def emit(text)
    if @fragment
      text.bytes.each { |byte| $stdout.write(byte.chr); sleep 0.0002 }
    else
      $stdout.write(text)
    end
  end
  def prompt
    if @adapter == 'junos'
      @mode == :config ? 'lab@router# ' : 'lab@router> '
    else
      @mode == :config ? 'router(config)#' : 'router#'
    end
  end
  def read_line(interactive: false)
    line = ''.b
    loop do
      char = $stdin.getc
      return nil unless char
      if char == "\x03" && interactive
        line.clear
        emit("\r\n#{prompt}")
      elsif char == "\r" || char == "\n"
        return line
      else
        line << char
      end
    end
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
    if username != 'lab' || password != 'secret'
      emit("\r\nAuthentication failed\r\n")
      return
    end
    emit("\r\n#{prompt}")
    while (command = read_line(interactive: true))
      emit("#{command}\r\n")
      case command
      when ''
      when 'terminal length 0', 'set cli screen-length 0'
      when 'show version'
        emit("Simulator #{@adapter}\r\n  quoted spaces stay   here\r\n\r\nBuild 42\r\n")
      when 'show paged'
        3.times do |page|
          emit("page #{page + 1}\r\n")
          if page < 2
            emit(' --More-- ')
            return unless $stdin.getc == ' '
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
        return
      when 'configure terminal', 'configure exclusive'
        if @scenario == 'locked'
          emit("error: configuration database locked\r\n")
        else
          @mode = :config
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
        @mode = :exec
      when 'exit'
        break if @mode == :exec
        @mode = :exec
      when 'bad command'
        emit(@adapter == 'ios' ? "% Invalid input detected at '^' marker.\r\n" : "error: syntax error\r\n")
      else
        if @mode == :config
          @adapter == 'ios' ? @running << command : @pending << command
        else
          emit("% Invalid input detected at '^' marker.\r\n")
        end
      end
      emit(prompt)
    end
  end
end
RouterCLI.new(ARGV).run
