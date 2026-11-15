# Compare the shipped primitive across Ruby versions, without loading expect4r.
require 'expect'
require 'digest'
require 'json'

source = $LOADED_FEATURES.find { |path| path.end_with?('/expect.rb') }
puts JSON.generate(ruby: RUBY_VERSION, expect_source_sha256: Digest::SHA256.file(source).hexdigest)

def check(name, data, pattern)
  reader, writer = IO.pipe
  writer.write(data)
  writer.close
  puts JSON.generate(probe: name, result: reader.expect(pattern, 0.05))
ensure
  reader&.close
  writer&.close unless writer&.closed?
end

check('multiline pattern', "first\r\nsecond>", /first\r\nsecond>/)
check('literal substring and prefix', 'prefix ready>', 'ready>')
check('captures', 'value=42>', /value=(\d+)>/)
check('EOF after partial output', 'partial', /never/)

reader, writer = IO.pipe
producer = Thread.new { 12.times { sleep 0.03; writer.write('x') } }
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = reader.expect(/never/, 0.1)
puts JSON.generate(probe: 'timeout while output keeps arriving', result: result,
                   elapsed: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
producer.join
reader.close
writer.close
