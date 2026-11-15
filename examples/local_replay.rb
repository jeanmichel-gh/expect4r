# frozen_string_literal: true
require 'expect4r'
require 'rbconfig'
require 'tmpdir'

def dialogue(session)
  session.expect!('ready>', timeout: 5)
  session.send_line('hello')
  result = session.capture_until!('ack', total_timeout: 5)
  session.expect!(:eof, timeout: 5)
  result.output
end

Dir.mktmpdir('expect4r-example-') do |directory|
  path = File.join(directory, 'dialogue.jsonl')
  original = File.open(path, 'wb') do |file|
    Expect4r.spawn(RbConfig.ruby, '-e', 'STDOUT.sync=true; print "ready>"; STDIN.gets; print "ack"', recording: file) do |session|
      dialogue(session)
    end
  end
  replayed = Expect4r.replay(path, fragment_size: 1, require_all_reads: true) { |session| dialogue(session) }
  raise 'Replay output differs' unless original == replayed
  puts 'Recorded local PTY and replayed it one byte at a time'
end
