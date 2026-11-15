# frozen_string_literal: true
require_relative '../test_helper'
class LifecycleTest < CoreTest
  def test_argv_env_and_child_directory_do_not_change_parent
    before = ENV['EXPECT4R_CHILD']
    Dir.mktmpdir do |dir|
      child('print [ARGV.first, ENV.fetch("EXPECT4R_CHILD"), Dir.pwd].join("|")',
            env: { 'EXPECT4R_CHILD' => 'child' }, chdir: dir) do |session|
        result = session.expect!(:eof, timeout: 2)
        assert_include result.before, "child|#{File.realpath(dir)}"
        assert session.wait(timeout: 1).success?
      end
    end
    assert_equal before, ENV['EXPECT4R_CHILD']
    Expect4r.spawn(RbConfig.ruby, '-e', '$stdout.sync=true; print ARGV.first', 'literal;$(echo unsafe)') do |session|
      assert_equal 'literal;$(echo unsafe)', session.expect!(:eof, timeout: 2).before
    end
  end
  def test_failed_spawn_and_invalid_owned_io_settings
    error = assert_raise(Expect4r::SpawnError) { Expect4r.spawn('/no/such/expect4r-executable') }
    assert_kind_of Errno::ENOENT, error.cause.cause
    assert_equal Errno::ENOENT::Errno, error.errno
    left, right = Socket.pair(:UNIX, :STREAM, 0)
    assert_raise(ArgumentError) { Expect4r.open(left, own: true, buffer_limit: 0) }
    assert !left.closed?
  ensure
    left&.close
    right&.close
  end
  def test_owned_and_borrowed_transports
    left, right = Socket.pair(:UNIX, :STREAM, 0)
    borrowed = Expect4r.open(left)
    borrowed.close
    borrowed.close
    assert !left.closed?
    assert_raise(IOError) { borrowed.write('') }
    assert_raise(Expect4r::UnsupportedOperation) { borrowed.wait }
    Expect4r.open(left, own: true).close
    assert left.closed?
  ensure
    left&.close unless left&.closed?
    right&.close
  end
  def test_exception_nonlocal_return_and_stubborn_child_cleanup
    captured = nil
    error = assert_raise(RuntimeError) do
      child('trap("HUP") {}; trap("TERM") {}; print "ready"; sleep 10') do |session|
        captured = session
        session.expect!('ready')
        raise 'application failure'
      end
    end
    assert_equal 'application failure', error.message
    assert captured.closed?
    assert !captured.alive?
    assert_equal Signal.list.fetch('KILL'), captured.process_status.termsig
    assert_equal :returned, early_return
    assert @returned_session.closed?
  end
  def early_return
    child('sleep 10') do |session|
      @returned_session = session
      return :returned
    end
  end
  def test_reentrancy_and_cross_thread_ownership
    with_input('one two') do |session|
      session.expect do
        on('one') do
          begin
            expect('two')
          rescue Expect4r::ReentrancyError
            write('response')
            exp_continue
          end
        end
        on 'two'
      end
    end
    with_input do |session|
      queue = Queue.new
      worker = Thread.new { queue << true; session.expect('never', timeout: 0.15) }
      queue.pop
      Thread.pass until worker.status == 'sleep'
      assert_raise(Expect4r::BusySessionError) { session.write('cannot race') }
      worker.join
    end
  end
  def test_backpressure_reports_progress_and_never_repeats_prefix
    with_input do |session, peer|
      data = 'x' * 2_000_000
      error = assert_raise(Expect4r::WriteTimeout) { session.write(data, timeout: 0.02) }
      assert_operator error.bytes_written, :>, 0
      assert_operator error.bytes_written, :<, data.bytesize
      received = ''.b
      loop do
        part = peer.read_nonblock(65_536, exception: false)
        break if part == :wait_readable
        received << part
      end
      assert_equal error.bytes_written, received.bytesize
      assert_equal data.byteslice(0, error.bytes_written), received
    end
  end
  def test_partial_sink_and_redaction_across_reads
    sink, diagnostic = StringIO.new, StringIO.new
    logger = Logger.new(diagnostic)
    with_input('', transcript: sink, logger:) do |session, peer|
      session.trace_bytes = true
      session.send_line('secret', sensitive: true)
      producer = Thread.new { peer.write('prefix sec'); sleep 0.02; peer.write("ret suffix>") }
      result = session.expect!('suffix>', timeout: 1)
      assert_equal 'prefix secret ', result.before
      producer.join
    end
    assert_equal 'prefix [REDACTED] suffix>', sink.string
    assert_not_include diagnostic.string, 'secret'
    assert_not_include result.inspect, 'secret' if defined?(result) && result
  end
  def test_overlapping_secrets_and_long_transcript
    redactor = Expect4r::Redactor.new
    redactor.add('pass')
    redactor.add('password')
    assert_equal '', redactor.feed('pass')
    assert_equal '[REDACTED]!', redactor.feed('word!')
    with_input('', transcript: StringIO.new, buffer_limit: nil) do |session, peer|
      session.redact('secret')
      producer = Thread.new { peer.write(('ordinary line\n' * 20_000) + 'done>') }
      assert session.expect!('done>', timeout: 3).matched?
      producer.join
    end
  end
  def test_primary_error_survives_transcript_close_failure
    sink = Object.new
    def sink.write(_bytes) = raise(IOError, 'sink failed')
    captured = nil
    error = assert_raise(RuntimeError) do
      child('print "sec"; sleep 10', transcript: sink) do |session|
        captured = session
        session.redact('secret')
        session.expect!('sec')
        raise 'primary'
      end
    end
    assert_equal 'primary', error.message
    assert captured.closed?
    assert !captured.alive?
    assert_equal 1, captured.cleanup_errors.size
  end
  def test_expired_action_budget_prevents_a_write
    with_input('ready') do |session, peer|
      error = assert_raise(Expect4r::WriteTimeout) do
        session.expect(timeout: 0.01) do
          on('ready') { sleep 0.03; write('too late') }
        end
      end
      assert_equal 0, error.bytes_written
      assert_equal :wait_readable, peer.read_nonblock(1, exception: false)
    end
  end
end
