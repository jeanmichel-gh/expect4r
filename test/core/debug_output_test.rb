# frozen_string_literal: true
require_relative '../test_helper'

class DebugOutputTest < CoreTest
  def test_matching_trace_is_scoped_and_keeps_callback_metadata_only
    output, events = StringIO.new, []
    with_input("ready \r\n", diagnostics: events.method(:<<), label: 'lab') do |session, peer|
      result = session.with_debug(output:, bytes: true) do |current|
        assert_same session, current
        current.expect!('ready')
      end
      assert result.matched?
      assert_include output.string, 'event=:rule_attempt'
      assert_include output.string, 'label="lab"'
      assert_include output.string, 'ready \\r\\n'
      length = output.string.bytesize
      session.expect!(" \r\n")
      assert_equal length, output.string.bytesize
      assert events.all? { |event| !event.key?(:preview) && !event.key?(:data) }
    end
  end

  def test_metadata_default_and_event_level_skip_previews_and_rule_attempts
    output = StringIO.new
    with_input('private payload') do |session, peer|
      session.with_debug(output:, level: :events) { session.expect!('private') }
      assert_not_include output.string, 'private'
      assert_not_include output.string, 'preview='
      assert_not_include output.string, 'event=:rule_attempt'
      assert_include output.string, 'event=:match'
    end
  end

  def test_hex_and_escaped_bytes_are_bounded_and_terminal_safe
    [:hex, :escaped].each do |format|
      output = StringIO.new
      with_input("prefix\x1b\x00\xff\r\n".b) do |session, peer|
        session.with_debug(output:, format:, bytes: true, preview_limit: 5) { session.expect!("\r\n") }
        assert_include output.string, 'omitted_bytes=6'
        assert_not_include output.string, "\x1b"
        if format == :hex
          assert_include output.string, '1b 00 ff 0d 0a'
        else
          assert_include output.string, '\\e\\x00\\xFF\\r\\n'
        end
      end
    end
  end

  def test_fragmented_secrets_are_filtered_before_formatting
    [:hex, :escaped].each do |format|
      output = StringIO.new
      with_input('pass') do |session, peer|
        session.redact('password')
        session.with_debug(output:, bytes: true, format:) do
          session.expect! do
            on('pass') { peer.write('word>'); exp_continue }
            on('>')
          end
          session.write('pass')
          session.write('word')
        end
        text = output.string
        assert_include text, 'preview=[suppressed:registered_secret]'
        assert_not_include text, 'password'
        assert_not_include text, 'pass'
        assert_not_include text, '70 61 73 73'
        assert_include text, format == :hex ? '5b 52 45 44 41 43 54 45 44 5d' : '[REDACTED]'
      end
    end
  end

  def test_sensitive_send_and_scope_start_mid_secret_do_not_leak
    output = StringIO.new
    with_input do |session, peer|
      session.redact('password')
      session.write('pass') # Prefix before the scope must remain filtered.
      session.with_debug(output:, bytes: true) do
        session.write('word')
        session.send_line('another-secret', sensitive: true)
      end
      assert_not_include output.string, 'word'
      assert_not_include output.string, 'another-secret'
      assert_include output.string, '[REDACTED]'
    end
  end

  def test_nested_scope_and_exception_restore_previous_output
    outer, inner = StringIO.new, StringIO.new
    with_input('abc') do |session, peer|
      session.with_debug(output: outer) do
        session.expect!('a')
        original = outer.string.bytesize
        assert_raise(RuntimeError) do
          session.with_debug(output: inner) { session.expect!('b'); raise 'stop' }
        end
        assert_equal original, outer.string.bytesize
        session.expect!('c')
        assert_operator outer.string.bytesize, :>, original
        assert_include inner.string, 'event=:match'
      end
    end
  end

  def leave_scope(session, output)
    session.with_debug(output:) { return :returned }
  end
  def test_nonlocal_exit_restores_settings_and_lease
    output = StringIO.new
    with_input('ready') do |session, peer|
      assert_equal :returned, leave_scope(session, output)
      assert session.expect!('ready').matched?
      assert_equal '', output.string
    end
  end

  def test_debug_sink_partial_writes_and_failure_restore_ownership
    partial = Class.new do
      attr_reader :text
      def initialize = @text = ''.b
      def write(bytes)
        @text << bytes.byteslice(0, 3)
        [bytes.bytesize, 3].min
      end
    end.new
    broken = Object.new
    def broken.write(bytes) = raise(IOError, 'debug sink failed')
    with_input('ab') do |session, peer|
      session.with_debug(output: partial) { session.expect!('a') }
      assert_include partial.text, 'event=:match'
      error = assert_raise(IOError) { session.with_debug(output: broken) { session.expect!('b') } }
      assert_equal 'debug sink failed', error.message
      assert session.expect!('b').matched?
    end
  end

  def test_scope_rejects_concurrent_session_access
    with_input('ready') do |session, peer|
      session.with_debug(output: StringIO.new) do
        error = Thread.new do
          begin
            session.expect('ready')
          rescue StandardError => failure
            failure
          end
        end.value
        assert_kind_of Expect4r::BusySessionError, error
        assert session.expect!('ready').matched?
      end
    end
  end

  def test_invalid_configuration_is_rejected_before_scope
    with_input('ready') do |session, peer|
      [{ level: :unknown }, { format: :unknown }, { bytes: nil }, { preview_limit: 0 }].each do |options|
        assert_raise(ArgumentError) { session.with_debug(**options) {} }
      end
      assert_raise(TypeError) { session.with_debug(output: Object.new) {} }
      assert_raise(ArgumentError) { session.with_debug }
      assert session.expect!('ready').matched?
    end
  end
  def test_metadata_scope_does_not_build_snapshots_or_change_old_controls
    output = StringIO.new
    with_input('ready') do |session, peer|
      def session.diagnostic_snapshot = raise('snapshot should stay lazy')
      assert_equal false, session.trace_bytes
      session.with_debug(output:) { session.expect!('ready') }
      assert_equal false, session.trace_bytes
      assert_not_include output.string, 'preview='
    end
  end

end
