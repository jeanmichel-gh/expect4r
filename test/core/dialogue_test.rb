# frozen_string_literal: true
require_relative '../test_helper'
class DialogueTest < CoreTest
  def test_literal_multiline_captures_and_suffix
    with_input("notice first\r\nvalue=42>tail") do |session|
      result = session.expect!(/first\r\nvalue=(\d+)>/, timeout: 1)
      assert_equal ['notice ', "first\r\nvalue=42>", ['42'], 'tail'], [result.before, result.match, result.captures, result.after]
      assert_equal 'tail', session.expect!('tail', timeout: 0).match
      assert result.frozen?
      assert result.before.frozen?
      assert result.captures.frozen?
    end
  end
  def test_declaration_priority_and_names
    with_input('early late') do |session|
      result = session.expect! do
        on 'late', name: :late
        on 'early', name: :early
      end
      assert_equal :late, result.name
      assert_equal 0, result.pattern_index
      assert_equal 'early ', result.before
    end
  end
  def test_real_pty_dialogue_and_cleanup
    captured = nil
    value = child('print "Name: "; n=gets.strip; print "hello #{n}>"; gets') do |session|
      captured = session
      result = session.expect!(timeout: 1) do
        on 'Name: ' do
          send_line 'Ruby'
          exp_continue
          raise 'continuation did not transfer control'
        end
        on 'hello Ruby>', name: :ready
      end
      assert_equal :ready, result.name
      123
    end
    assert_equal 123, value
    assert captured.closed?
    assert !captured.alive?
    assert captured.process_status.signaled?
    assert_equal captured.process_status, captured.close
  end
  def test_literal_is_not_a_regexp
    with_input('prefix a.b tail') do |session|
      result = session.expect!('a.b', timeout: 1)
      assert_equal 'prefix ', result.before
      assert_equal [], result.captures
    end
  end
  def test_explicit_callbacks_get_result_and_session_context
    expected = nil
    with_input('one two') do |session|
      expected = session
      result = session.expect! do |patterns|
        patterns.on('one') do |event|
          raise 'bad context' unless equal?(expected) && event.session.equal?(expected)
          exp_continue(reset_timeout: false)
        end
        patterns.on('two', name: :second)
      end
      assert_equal :second, result.name
    end
  end
  def test_timeout_and_eof_bang_acknowledgement
    with_input('partial', eof: true) do |session|
      error = assert_raise(Expect4r::UnexpectedEOF) { session.expect!('missing', timeout: 1) }
      assert_equal 'partial', error.result.before
      assert session.expect!(:eof).eof?
      assert_equal '', session.expect(:eof).before
    end
    with_input do |session|
      error = assert_raise(Expect4r::ExpectTimeout) { session.expect!('missing', timeout: 0.01) }
      assert error.result.timeout?
      event = session.expect!(timeout: 0.01) { timeout { |result| raise 'bad reason' unless result.reason == :timeout } }
      assert event.timeout?
    end
  end
  def test_nonconsuming_and_empty_matches
    with_input('ready>') do |session|
      assert session.expect('ready>', consume: false).matched?
      assert_equal 'ready>', session.buffer
      assert_raise(Expect4r::InvalidContinuation) do
        session.expect(consume: false) { on('ready>') { exp_continue } }
      end
      assert_equal 'ready>', session.buffer
      assert_raise(Expect4r::EmptyMatchError) { session.expect(/\A/) }
      assert_equal 'ready>', session.buffer
      assert_raise(Expect4r::EmptyMatchError) { session.expect('') }
    end
  end
  def test_registration_validation_does_not_consume
    with_input('ready') do |session|
      assert_raise(ArgumentError) do
        session.expect do
          on 'ready', name: :same
          on 'other', name: :same
        end
      end
      assert session.expect!('ready').matched?
    end
  end
  def test_rules_are_reusable_and_limits_do_not_consume_failure
    rules = Expect4r.rules do
      on 'page', name: :page, limit: 1 do
        exp_continue(reset_timeout: false)
      end
    end
    2.times do
      with_input('pagepage done') do |session|
        assert_raise(Expect4r::ResponseLimitError) { session.expect { use rules; on 'done' } }
        assert_equal 'page done', session.buffer
      end
    end
  end
  def test_overflow_keeps_prefix_and_rejected_bytes
    with_input('abcdefgh', buffer_limit: 4) do |session|
      error = assert_raise(Expect4r::BufferOverflow) { session.expect('never') }
      assert_equal 'abcdefgh', error.buffer + error.rejected
      assert_equal 'abcd', session.buffer
      assert_raise(Expect4r::BufferOverflow) { session.expect('a') }
      assert_equal 'abcd', session.clear_buffer
    end
  end
  def test_utf8_fragment_and_capture_byte_offsets
    with_input do |session, peer|
      producer = Thread.new { peer.write('pré'.encode('UTF-8').byteslice(0, 3)); sleep 0.02; peer.write("é café>".byteslice(1..)) }
      result = session.expect!(/pré (café)>/u, timeout: 1)
      assert_equal 'pré café>'.b, result.match
      assert_equal ['café'.b], result.captures
      producer.join
    end
  end
  def test_invalid_encoding_and_binary_regex
    with_input("\xff", eof: true) do |session|
      assert_raise(Expect4r::EncodingError) { session.expect(/café/u) }
      assert session.expect(/\xff/n).matched?
    end
  end
  def test_callbacks_propagate_and_release_ownership
    with_input('one two') do |session|
      assert_raise(RuntimeError) { session.expect { on('one') { raise 'application failure' } } }
      assert session.expect('two').matched?
    end
  end
  def test_no_global_core_patches
    assert !IO.method_defined?(:readbuf)
    assert !Kernel.method_defined?(:exp_internal)
    assert !defined?(Expect4r::Base)
  end
end
