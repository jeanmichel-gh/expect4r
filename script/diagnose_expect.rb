# Behavioral probes for the legacy engine, not assertions of desired behavior.
# Run: bundle exec ruby -Ilib script/diagnose_expect.rb
require 'expect4r/legacy'
require 'timeout'
require 'json'

def probe(name, pattern, timeout, chunks, matches = [])
  reader, writer = IO.pipe
  session = Expect4r::Base.new
  session.instance_variable_set(:@r, reader)
  producer = Thread.new do
    chunks.each do |delay, data|
      sleep delay
      writer.write(data)
    end
    # Keep the writer open so silence is distinct from EOF.
  end
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = begin
    Timeout.timeout(2) { session.expect(pattern, timeout, matches) }
    'matched'
  rescue StandardError => error
    error.class.name
  end
  puts JSON.generate(probe: name, result: result,
                     elapsed: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
ensure
  producer&.kill
  producer&.join
  reader&.close
  writer&.close
  Expect4r::Base.all.delete(session)
end

probe('multiline pattern', /first\r\nsecond>/, 0.05, [[0, "first\r\nsecond>"]])
probe('exact substring', 'ready>', 0.05, [[0, 'prefix ready>']])
probe('timeout while output keeps arriving', /never/, 0.1, Array.new(12) { [0.03, 'x'] })
called = false
probe('callback ending in newline', /done>/, 0.05, [[0, "confirm\r\n"]],
      [[/confirm\r\n/, lambda { |_session| called = true }]])
puts JSON.generate(probe: 'newline callback ran', result: called)

reader, writer = IO.pipe
writer.write('partial output')
writer.close
session = Expect4r::Base.new
session.instance_variable_set(:@r, reader)
begin
  Timeout.timeout(0.2) { session.expect(/never/, 0.05) }
rescue StandardError => error
  puts JSON.generate(probe: 'EOF after partial output on pipe', result: error.class.name)
ensure
  reader.close
  Expect4r::Base.all.delete(session)
end
