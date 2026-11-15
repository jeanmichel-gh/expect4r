# frozen_string_literal: true
require 'expect4r'
require 'rbconfig'
program = <<~'CHILD'
  $stdout.sync = true
  print 'Name: '
  name = $stdin.gets&.strip
  puts "Hello #{name}"
  print 'ready> '
  $stdin.gets
CHILD
Expect4r.spawn(RbConfig.ruby, '-e', program) do |session|
  result = session.expect!(timeout: 2, total_timeout: 5) do
    on 'Name: ' do
      send_line 'Jean-Michel'
      exp_continue
    end
    on /Hello ([^\r\n]+)\r?\n/ do |match|
      puts "Greeting for #{match.captures.first}"
      exp_continue(reset_timeout: false)
    end
    on 'ready> ', name: :ready
  end
  puts "Reached #{result.name}"
  session.send_line 'exit'
  session.expect!(:eof, timeout: 2)
  raise 'child failed' unless session.wait(timeout: 2)&.success?
end
