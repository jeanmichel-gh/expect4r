# frozen_string_literal: true
require 'expect4r'
require 'rbconfig'
require 'io/console'

abort 'Run this example in a real Terminal window.' unless $stdin.tty? && $stdout.tty?
escape_key = ARGV.fetch(0, 'C-]')
$stdout.sync = true

# Normalize the kernel's first raw/canonical transition (macOS may set PENDIN).
saved = $stdin.console_mode
begin
  $stdin.raw!
ensure
  $stdin.console_mode = saved
end
before = IO.popen(['stty', '-g'], 'r', in: $stdin, &:read)

program = <<~'CHILD'
  $stdout.sync = true
  manual_seen = false
  loop do
    print 'manual> '
    case $stdin.gets&.strip
    when 'manual-check'
      manual_seen = true
      puts 'MANUAL_OK'
    when 'automatic-check'
      puts(manual_seen ? 'AUTOMATION_OK' : 'MANUAL_STEP_MISSING')
    when 'quit', nil
      break
    else
      puts 'Type manual-check, then press Enter.'
    end
  end
CHILD

puts "Type manual-check, press Enter, and wait for the next manual> prompt."
puts "Then press #{escape_key} to return to Ruby (hold Control and press the key)."
Expect4r.spawn(RbConfig.ruby, '-e', program) do |session|
  result = session.interact(escape_key:)
  raise "Expected return-key exit, got #{result.reason}" unless result.reason == :escape
  puts "\nRETURNED_TO_RUBY"
  after = IO.popen(['stty', '-g'], 'r', in: $stdin, &:read)
  raise 'Terminal settings were not restored' unless before == after
  puts 'TERMINAL_RESTORED'
  session.send_line('automatic-check')
  reply = session.expect!(/(?:\A|(?<=\n))(AUTOMATION_OK|MANUAL_STEP_MISSING)\r?\n/n, timeout: 3)
  raise 'Manual step missing: run again and type manual-check first' unless reply.captures.first == 'AUTOMATION_OK'
  session.send_line('quit')
  session.expect!(:eof, timeout: 3)
  raise 'Local child did not exit successfully' unless session.wait(timeout: 2)&.success?
  puts 'INTERACT_CHECK_PASSED'
end
