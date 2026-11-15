# frozen_string_literal: true
require 'expect4r'
require 'tempfile'
require 'digest'

def check(condition, message)
  raise message unless condition
end

ssh = ['ssh', '-tt', '-p', '2222', '-o', 'StrictHostKeyChecking=yes',
       '-o', 'UserKnownHostsFile=/run/playground-known-hosts',
       '-o', 'PreferredAuthentications=password', '-o', 'NumberOfPasswordPrompts=1',
       'lab@127.0.0.1']

# A rejected password must become EOF + an unsuccessful exit, never a shell prompt.
Expect4r.spawn(*ssh, timeout: 15) do |s|
  s.expect!(/password: ?\z/)
  s.send_line 'deliberately-wrong-password', sensitive: true
  result = s.expect('lab> ')
  check(result.status == :eof, 'rejected login did not reach EOF')
  check(result.before.include?('Permission denied'), 'missing login rejection')
  check(s.wait(timeout: 5)&.exitstatus == 255, 'unexpected SSH rejection exit status')
end
puts 'REJECTED_LOGIN_PASSED'

# An abruptly exiting remote shell must preserve output and distinguish EOF from timeout.
Expect4r.spawn(*ssh, timeout: 15) do |s|
  s.expect!(/password: ?\z/)
  s.send_line 'lab-password', sensitive: true
  s.expect!('lab> ')
  s.send_line "printf '\\n%s\\n' BEFORE_DISCONNECT; kill -KILL $$"
  s.expect!(/\r?\nBEFORE_DISCONNECT\r?\n/)
  result = s.expect('lab> ')
  check(result.status == :eof, 'remote shell loss did not become EOF')
  check(!s.wait(timeout: 5)&.success?, 'killed remote shell reported success')
end
puts 'DISCONNECTED_SESSION_PASSED'

# Real Python output larger than the matcher: verify every byte, not only the tail.
payload = '0123456789abcdef' * 196_608 # 3 MiB, no terminal newline conversion
Tempfile.create('expect4r-large-output') do |sink|
  sink.binmode
  Expect4r.spawn('python3', '-c', 'import sys; sys.stdout.write("0123456789abcdef" * 196608 + "DONE>")',
                 buffer_limit: 4096) do |s|
    result = s.capture_until!('DONE>', sink: sink, retain: 128, total_timeout: 30)
    check(result.output_bytes == payload.bytesize, 'large output count mismatch')
    check(result.sink_bytes == payload.bytesize, 'large sink count mismatch')
    check(result.output == payload.byteslice(-128, 128), 'retained tail mismatch')
    check(result.truncated, 'missing retained-tail truncation flag')
    sink.flush
    check(Digest::SHA256.file(sink.path).hexdigest == Digest::SHA256.hexdigest(payload), 'large output corrupted')
    s.expect!(:eof)
    check(s.wait(timeout: 5)&.success?, 'large output child failed')
  end
end
puts 'LARGE_OUTPUT_PASSED'

# A stalled capture returns its partial bytes; interrupt the process and keep using the session.
Expect4r.spawn('python3', '-u', '-c',
               'import time; print("PARTIAL", flush=True); time.sleep(100)', timeout: 10) do |s|
  s.expect!(/PARTIAL\r?\n/, consume: false) # ensure producer reached its sleep
  result = s.capture_until('NEVER>', timeout: 0.2)
  check(result.status == :timeout, 'stalled capture did not time out')
  check(result.output == "PARTIAL\r\n", 'partial capture bytes lost')
  s.write "\x03"
  s.expect!(:eof)
  check(!s.wait(timeout: 5)&.success?, 'interrupted child reported success')
end
puts 'INTERRUPTED_CAPTURE_PASSED'
