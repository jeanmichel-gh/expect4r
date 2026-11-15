# frozen_string_literal: true
require_relative '../test_helper'
class FullBufferTest < CoreTest
  def test_large_read_streams_explicit_prefixes_and_preserves_boundary_match
    events, output = [], ''.b
    transcript, recording = StringIO.new, StringIO.new
    with_input('abcabcENDtail', buffer_limit: 3, diagnostics: events.method(:<<), transcript:, recording:) do |session, peer|
      result = session.expect! do
        on 'END'
        full_buffer do |event|
          output << consume_buffer(event.before.bytesize)
          exp_continue(reset_timeout: false)
        end
      end
      assert_equal 'abcabc', output
      assert_equal 'END', result.match
      assert_equal 'tail', session.staged_buffer
      assert_equal 'tail', result.staged.fetch(session)
      assert result.staged.fetch(session).frozen?
      assert_equal 'abcabcENDtail', transcript.string
      assert_equal 13, events.find { |e| e[:event] == :receive }[:bytes]
      rx = recording.string.lines.map { |line| JSON.parse(line) }.select { |e| e['type'] == 'payload' && e['direction'] == 'rx' }
      assert_equal 'abcabcENDtail', rx.map { |e| e['data'].unpack1('m0') }.join
      assert_equal 9, session.buffer_offset
      assert_equal 1, events.count { |e| e[:event] == :receive }
      assert_equal 2, events.count { |e| e[:event] == :full_buffer }
      assert session.expect!('tai').matched?
      assert_equal 'l', session.staged_buffer
    end
  end
  def test_match_at_capacity_wins_over_full_buffer
    with_input('abcXYZ', buffer_limit: 3) do |session, peer|
      result = session.expect! do
        on 'abc'
        full_buffer { raise 'must not run' }
      end
      assert_equal 'abc', result.match
      assert_equal 'XYZ', session.staged_buffer
      assert session.expect!('XYZ').matched?
    end
  end
  def test_growth_and_ceiling_allow_longer_match
    with_input('abcdefgh', buffer_limit: 3, buffer_ceiling: 8) do |session, peer|
      session.expect! do
        on 'abcdefgh'
        full_buffer { resize_buffer(8); exp_continue(reset_timeout: false) }
      end
      assert_equal 8, session.buffer_limit
      assert_equal 8, session.buffer_offset
      assert_raise(ArgumentError) { session.resize_buffer(9) }
      assert_raise(ArgumentError) { session.resize_buffer(nil) }
    end
  end
  def test_unknown_progress_is_rejected_and_input_is_retained
    with_input('abcdef', buffer_limit: 3) do |session, peer|
      error = assert_raise(Expect4r::BufferProgressError) do
        session.expect! { on 'never'; full_buffer { exp_continue } }
      end
      assert error.result.full_buffer?
      assert_equal 'abc', session.buffer
      assert_equal 'def', session.staged_buffer
      assert_equal false, session.buffer_recovery
      assert_equal 'abcdef', session.clear_buffer
      assert_equal 6, session.buffer_offset
    end
  end
  def test_callback_failure_keeps_staged_remainder_for_later_wait
    with_input('abcEND', buffer_limit: 3) do |session, peer|
      assert_raise(RuntimeError) do
        session.expect! { on 'END'; full_buffer { raise 'sink failed' } }
      end
      assert_equal 'abc', session.buffer
      assert_equal 'END', session.staged_buffer
      result = session.expect! do
        on 'END'
        full_buffer { consume_buffer(3); exp_continue(reset_timeout: false) }
      end
      assert_equal 'END', result.match
    end
  end
  def test_returning_full_buffer_result_requires_progress_and_immutable_snapshot
    with_input('abcdef', buffer_limit: 3) do |session, peer|
      result = session.expect! { full_buffer { consume_buffer(2) } }
      assert result.full_buffer?
      assert_equal 'abc', result.before
      assert result.before.frozen?
      assert_equal 'c', session.buffer
      assert_equal 'def', session.staged_buffer
      assert_raise(ArgumentError) { session.resize_buffer(0) }
      session.resize_buffer(1)
      assert_raise(ArgumentError) { session.consume_buffer(2) }
    end
  end
  def test_default_overflow_contract_is_unchanged
    with_input('abcdef', buffer_limit: 3) do |session, peer|
      error = assert_raise(Expect4r::BufferOverflow) { session.expect('never') }
      assert_equal 'abc', error.buffer
      assert_equal 'def', error.rejected
      assert_empty session.staged_buffer
      assert_raise(Expect4r::BufferOverflow) { session.expect('abc') }
      assert_equal 'abc', session.clear_buffer
    end
  end
  def test_wait_without_handler_reports_preserved_staged_overflow
    with_input('abcdef', buffer_limit: 3) do |session, peer|
      session.expect! { full_buffer { consume_buffer(1) } }
      error = assert_raise(Expect4r::BufferOverflow) { session.expect('never') }
      assert_equal 'bcd', error.buffer
      assert_equal 'ef', error.rejected
      assert_equal 'ef', session.staged_buffer
      assert_equal 'bcdef', session.clear_buffer
    end
  end
  def test_handler_keeps_total_and_idle_deadlines
    [:total_timeout, :idle_timeout].each do |reason|
      options = { timeout: 1, reason => 0.01 }
      with_input('abcEND', buffer_limit: 3) do |session, peer|
        result = session.expect(**options) do
          on 'END'
          full_buffer do
            sleep 0.02
            consume_buffer(3)
            exp_continue(reset_timeout: false)
          end
        end
        assert result.timeout?
        assert_equal reason, result.reason
        assert_equal 'END', session.staged_buffer
        assert_equal 'END', result.staged.fetch(session)
      end
    end
  end
  def test_source_specific_handler_does_not_block_behind_unhandled_full_source
    with_input('aaa', buffer_limit: 3) do |first, first_peer|
      with_input('bbbEND', buffer_limit: 3) do |second, second_peer|
        result = Expect4r.expect!(from: [first, second]) do
          on 'END', from: second
          full_buffer(from: second) { consume_buffer(3); exp_continue(reset_timeout: false) }
        end
        assert_same second, result.session
        assert_equal 'aaa', first.buffer
      end
    end
  end
  def test_text_precedence_across_staged_sources
    with_input('aaax', buffer_limit: 3) do |first, peer|
      with_input('bbbY', buffer_limit: 3) do |second, second_peer|
        result = Expect4r.expect!(from: [first, second]) do
          on 'Y', from: second
          on 'x', from: first
          full_buffer { consume_buffer(3); exp_continue(reset_timeout: false) }
        end
        assert_equal 'Y', result.match
        assert_equal 'x', first.buffer
      end
    end
  end
  def test_utf8_split_at_capacity_can_grow_before_matching
    with_input('é'.b, buffer_limit: 1, buffer_ceiling: 2) do |session, peer|
      result = session.expect! do
        on(/é/)
        full_buffer { resize_buffer(2); exp_continue(reset_timeout: false) }
      end
      assert_equal 'é'.b, result.match
    end
  end
  def test_eof_after_full_buffer_recovery
    output = ''.b
    with_input('abcdef', buffer_limit: 3, eof: true) do |session, peer|
      result = session.expect! do
        eof
        full_buffer { |event| output << consume_buffer(event.before.bytesize); exp_continue(reset_timeout: false) }
      end
      assert result.eof?
      assert_equal 'abcdef', output
    end
  end
  def test_registration_and_mutation_validation
    with_input('abc', buffer_limit: 3) do |session, peer|
      assert_raise(ArgumentError) { session.expect(consume: false) { full_buffer { consume_buffer(1) } } }
      assert_raise(ArgumentError) { session.expect { full_buffer } }
      assert_raise(ArgumentError) { session.expect { full_buffer {}; full_buffer {} } }
      assert_raise(ArgumentError) { session.consume_buffer(-1) }
      session.expect!('a', consume: false)
      assert_raise(ArgumentError) { session.resize_buffer(2) }
    end
    assert_raise(ArgumentError) { Expect4r.spawn('unused', buffer_limit: 10, buffer_ceiling: 5) }
  end
  def test_nested_read_is_rejected_in_handler
    testcase = self
    with_input('abc', buffer_limit: 3) do |session, peer|
      session.expect! do
        full_buffer do
          testcase.assert_raise(Expect4r::ReentrancyError) { expect('anything') }
          consume_buffer(1)
        end
      end
    end
  end
  def test_interact_drains_staged_output_without_losing_manual_control
    output = StringIO.new
    input, feeder = IO.pipe
    feeder.write("\x14")
    with_input('abcDEF', buffer_limit: 3) do |session, peer|
      session.expect! { on 'abc'; full_buffer { raise 'boundary match must win' } }
      assert_equal 'DEF', session.staged_buffer
      result = session.interact(input:, output:, raw: false)
      assert_equal :escape, result.reason
      assert_equal 'DEF', output.string
      assert_empty session.staged_buffer
      assert_equal false, session.buffer_recovery
    end
  ensure
    input&.close
    feeder&.close
  end
  def test_handler_cannot_reset_total_deadline_with_continuation
    with_input('abcEND', buffer_limit: 3) do |session, peer|
      result = session.expect(timeout: 1, total_timeout: 0.01) do
        on 'END'
        full_buffer do
          sleep 0.02
          consume_buffer(3)
          exp_continue # Relative timeout resets; total timeout must not.
        end
      end
      assert_equal :total_timeout, result.reason
      assert_equal 'END', result.staged.fetch(session)
    end
  end

  def test_sustained_real_pty_output_uses_bounded_matching_and_staging
    consumed, largest_stage, largest_buffer = 0, 0, 0
    child('STDOUT.write("x" * 200_000 + "END")', buffer_limit: 4096) do |session|
      result = session.expect!(timeout: 5, total_timeout: 10) do
        on 'END'
        full_buffer do |event|
          largest_stage = [largest_stage, staged_bytes].max
          largest_buffer = [largest_buffer, buffer.bytesize].max
          consumed += consume_buffer(event.before.bytesize - 2).bytesize
          exp_continue(reset_timeout: false)
        end
      end
      assert_equal 200_000, consumed + result.before.bytesize
      assert_operator largest_stage, :<=, 65_536
      assert_equal 4096, largest_buffer
    end
  end
  def leave_full_buffer_scope(session)
    session.expect! { full_buffer { return :returned } }
  end
  def test_nonlocal_handler_return_restores_ownership_and_keeps_input
    with_input('abcDEF', buffer_limit: 3) do |session, peer|
      assert_equal :returned, leave_full_buffer_scope(session)
      assert_equal false, session.buffer_recovery
      session.resize_buffer(6)
      assert_equal 'abcDEF', session.expect!('abcDEF').match
    end
  end

  def test_zero_total_deadline_precedes_cached_full_buffer_even_with_zero_poll
    with_input('abcDEF', buffer_limit: 3) do |session, peer|
      session.expect! { full_buffer { consume_buffer(1) } }
      session.resize_buffer(2)
      result = session.expect(timeout: 0, total_timeout: 0) do
        full_buffer { raise 'expired total deadline must win' }
      end
      assert_equal :total_timeout, result.reason
      assert_equal 'DEF', result.staged.fetch(session)
    end
  end

end
