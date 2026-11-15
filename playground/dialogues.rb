# frozen_string_literal: true
require 'expect4r'

kind = ARGV.fetch(0, 'ssh')
commands = {
  'ssh' => ['ssh', '-tt', '-p', '2222', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'UserKnownHostsFile=/run/playground-known-hosts',
            '-o', 'PreferredAuthentications=password', 'lab@127.0.0.1'],
  'telnet' => ['telnet', '-K', '127.0.0.1', '2323'],
  'sqlite' => ['sqlite3', '-interactive', ':memory:'],
  'python' => ['python3', '-q']
}
argv = commands.fetch(kind) { abort "Choose: #{commands.keys.join(', ')}" }
debug_output = ENV['DEBUG'] == '1' ? $stderr : File.open(File::NULL, 'w')
recording = ENV['RECORD'] && File.open(ENV.fetch('RECORD'), 'w')
begin
  Expect4r.spawn(*argv, timeout: 10, recording: recording) do |s|
    s.redact('lab-password')
    s.with_debug(output: debug_output, level: :matching, bytes: false) do
      case kind
      when 'ssh', 'telnet'
        s.expect!(total_timeout: 20) do
          on /login: ?\z/ do
            send_line 'lab'
            exp_continue
          end
          on /[Pp]assword: ?\z/ do
            send_line 'lab-password', sensitive: true
            exp_continue
          end
          on 'lab> '
        end
        if ENV['MANUAL'] == '1'
          puts "Manual shell: #{ENV.fetch('ESCAPE_KEY', 'C-]')} returns to Ruby; the demo then interrupts any foreground command."
          s.interact(escape_key: ENV.fetch('ESCAPE_KEY', 'C-]'))
          puts 'RETURNED_TO_RUBY: interrupting foreground command to recover the shell.'
          s.write "\x03"
          s.send_line ''
          s.expect!(/(?:\A|[\r\n])lab> /)
        end
        s.send_line "printf '\\n%s\\n' SHELL_OK"
        s.expect!(/\r?\nSHELL_OK\r?\n/)
        s.expect!('lab> ')
        s.send_line 'sleep 1'
        result = s.expect('lab> ', timeout: 0.1)
        raise 'expected timeout' unless result.status == :timeout
        s.expect!('lab> ')
        s.send_line 'exit'
      when 'sqlite'
        s.expect!('sqlite> ')
        s.send_line 'select'
        s.expect!('   ...> ')
        s.send_line "'SQLITE_OK';"
        s.expect!(/\r?\nSQLITE_OK\r?\n/)
        s.expect!('sqlite> ')
        s.send_line '.quit'
      when 'python'
        s.expect!('>>> ')
        s.send_line 'for i in range(2):'
        s.expect!('... ')
        s.send_line '    print("PYTHON_OK", i)'
        s.expect!('... ')
        s.send_line ''
        s.expect!(/\r?\nPYTHON_OK 0\r?\nPYTHON_OK 1\r?\n/)
        s.expect!('>>> ')
        s.send_line 'exit()'
      end
      s.expect!(:eof)
      raise 'child failed' unless s.wait(timeout: 5)&.success?
    end
  end
  puts "#{kind.upcase}_CHECK_PASSED"
ensure
  recording&.close
  debug_output.close unless debug_output.equal?($stderr)
end
