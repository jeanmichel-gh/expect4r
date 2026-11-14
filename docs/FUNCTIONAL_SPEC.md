# expect4r v2 — functional specification

Status: v2 development contract. The current implementation and verified boundaries are recorded in IMPLEMENTATION.md; real-device support has not been validated.
Baseline: Ruby >= 4.0.6, Linux and macOS, POSIX PTYs. The v2 package now declares this Ruby baseline; legacy tests remain separately runnable on the supported runtime.

## 1. Product and scope

A general-purpose Ruby library for scripted conversations with terminal programs, with router automation built on the same conversation primitives. The primary abstraction is a session with ordered pattern/action alternatives. Ruby variables, methods and control flow remain available throughout.

The `Expect4r` namespace and gem name are retained for continuity. A future major release loads the new API through `require 'expect4r'`. Legacy behavior is isolated behind `require 'expect4r/legacy'` if a compatibility adapter proves useful; loading either entry point must not silently activate the other. The preserved source-only compatibility tree is now under `legacy/lib`, excluded from both new gems. Router functionality is packaged separately as `expect4r-routers` under `Expect4rRouters`.

The core is independent of router vendors, SSH credentials and prompt conventions. No IO/Kernel patches, global configuration, global session registry, modified thread exception policy or parent-process environment changes.

Tcl script interpretation and exact Tcl regular-expression compatibility are outside scope. The contract covers equivalent dialogue capabilities using Ruby syntax. Full Tcl feature parity is not claimed. Glob patterns, background event dispatch and arbitrary terminal-output filtering are deferred; see section 16.

## 2. The intended scripting experience

A complete proposed script using a local Ruby child:

```ruby
require 'expect4r'
require 'rbconfig'

child = <<~'RUBY'
  $stdout.sync = true
  print 'Name: '
  name = $stdin.gets&.strip
  puts "Hello #{name}"
  print 'ready> '
  $stdin.gets
RUBY

Expect4r.spawn(RbConfig.ruby, '-e', child) do |session|
  result = session.expect!(timeout: 2, total_timeout: 5) do
    on 'Name: ', name: :name do
      send_line 'Jean-Michel'
      exp_continue
    end

    on /Hello ([^\r\n]+)\r?\n/, name: :greeting do |match|
      puts "Greeting for #{match.captures.first}"
      exp_continue(reset_timeout: false)
    end

    on 'ready> ', name: :ready
  end

  puts result.name                         # :ready
  session.send_line 'exit'
  session.expect!(:eof, timeout: 2)
  status = session.wait(timeout: 2)
  raise 'child failed' unless status&.success?
end
```

The declaration block registers patterns without doing IO. Registration finishes before matching starts. Registration errors leave session input untouched.

Two forms of declaration are supported:

```ruby
# Compact form: self is a PatternSet during registration.
result = session.expect(timeout: 5) do
  on /ready>\s*\z/, name: :ready
  timeout { |event| warn "Wait expired: #{event.reason}" }
  eof { |event| warn "Connection ended with #{event.before.bytesize} bytes" }
end

# Explicit form: registration retains the caller's self.
result = session.expect(timeout: 5) do |patterns|
  patterns.on(/ready>\s*\z/, name: :ready)
  patterns.on(/Password: /, name: :password) do |event|
    event.session.send_line(password, sensitive: true)
    event.session.exp_continue
  end
end
```

For both forms, action blocks execute with `self` set to the matched Session and receive one Result argument. Aggregate multi-session timeout handlers have no source session and use the WaitContext described in section 13. Lexical local variables remain accessible. Call application methods through an explicit object if necessary. `Result#session` supports fully explicit code.

A callback's return value never becomes the return value of `expect`, and is never sent automatically. Without continuation, a completed action ends the wait and `expect` returns its Result. `return`, `break` and `throw` retain Ruby's normal nonlocal-control-flow consequences; ownership guards and outer factory cleanup must still execute.

## 3. Public API overview

Signatures below are descriptive, not Ruby type declarations. Unknown options raise `ArgumentError` before IO side effects.

| Operation | Return | Purpose |
|---|---|---|
| `Expect4r.spawn(*argv, env: {}, chdir: nil, shell: false, timeout: 10, write_timeout: 10, buffer_limit: 1_048_576, line_ending: "\r", logger: nil, transcript: nil) { ... }` | Session, or block value | Start and own a PTY child. |
| `Expect4r.open(reader, writer: reader, own: false, timeout: 10, write_timeout: 10, buffer_limit: 1_048_576, line_ending: "\r", logger: nil, transcript: nil) { ... }` | Session, or block value | Wrap selectable IO with explicit ownership. |
| `session.expect(*patterns, timeout: session.timeout, idle_timeout: nil, total_timeout: nil, consume: true) { ... }` | Result | Wait for one outcome. |
| `session.expect!(...)` | Result | Same operation, with timeout/EOF exceptions unless the event was explicitly requested. |
| `session.write(bytes, timeout: session.write_timeout, sensitive: false)` | Integer | Write unchanged bytes, handling partial writes. |
| `session.send_line(text = '', ending: session.line_ending, timeout: session.write_timeout, sensitive: false)` | Integer | Write exact text followed by the selected terminator. |
| `session.exp_continue(reset_timeout: true)` | Nonlocal control | Continue the current match operation after an action. |
| `session.interact(input: $stdin, output: $stdout, escape: "\x14", timeout: nil, raw: true)` | InteractionResult | Temporarily give terminal control to the user. |
| `session.close(grace: 1, kill_after: 1)` | Process::Status or nil | Release owned resources and reap the owned child. |
| `session.wait(timeout: 5)` | Process::Status or nil | Observe/reap child exit, without closing the session. |
| `session.terminate(signal: :TERM)` | nil | Signal the owned direct child. |
| `session.buffer` | Frozen String snapshot | Inspect unmatched bytes without reading or consuming. |
| `session.clear_buffer` | Frozen String | Explicitly retrieve and discard unmatched bytes. |
| `session.pid`, `command`, `closed?`, `eof?`, `alive?`, `process_status`, `last_result`, `cleanup_errors` | Read-only state | Observe distinct process, stream and wait state. |

Durations accept finite nonnegative real Numeric values or nil. Negative values, NaN, infinity, strings, booleans and Complex values raise `ArgumentError`. `nil` disables that particular time limit. `timeout: 0` scans buffered input and performs one nonblocking readiness poll; it never waits for future input. Explicit source lists must be nonempty and contain unique Session identities.

`write` and `send_line` accept String values; String subclasses are copied to ordinary byte strings. No implicit array flattening, whitespace normalization or stringification. Ruby's reflective `send` and `__send__` keep their original meaning.

## 4. Session creation and ownership

### 4.1 Direct execution

```ruby
session = Expect4r.spawn('ssh', '-o', 'StrictHostKeyChecking=yes', '-l', user, host)
session = Expect4r.spawn('ruby', '-e', 'puts ENV.fetch("APP_MODE")',
                         env: { 'APP_MODE' => 'test' }, chdir: '/tmp')

# A shell is an explicit choice; only one command string is accepted here.
session = Expect4r.spawn('printf ready | cat', shell: true)
```

Without `shell: true`, each argument is passed directly to the executable. A single string is an executable filename, not a shell command line. All argv entries must be nonempty Strings without NUL, except argument entries after the executable may be empty Strings. Shell mode uses `/bin/sh -c` and accepts exactly one command string. Environment changes apply only to the child.

A session owns its PTY descriptors, direct child PID and reaping responsibility. Failed startup raises `SpawnError` with `cause`, `command` and `errno` when available. It leaves no inaccessible child, descriptor or waiting thread. Immediate child exit still makes its output and eventual status available.

### 4.2 Borrowed IO

```ruby
require 'socket'

socket = TCPSocket.new('127.0.0.1', 2323)
Expect4r.open(socket, own: false, line_ending: "\r\n") do |session|
  session.send_line('help')
  puts session.expect!('ready> ', timeout: 2).before
end
raise 'borrowed socket was closed' if socket.closed?
socket.close
```

Reader and writer must support native nonblocking IO/readiness integration. StringIO and arbitrary callbacks are not transports in v2.0. Validate both handles and settings before taking ownership, including with `own: true`. Closing a borrowed session detaches its handles and makes further session operations fail, but leaves underlying IO open. Caller-owned IO may not be read concurrently while attached. `pid` and `process_status` are nil; `wait` and `terminate` raise `UnsupportedOperation`.

### 4.3 Block cleanup and concurrency

Factories return the block's value and ensure bounded cleanup on normal completion, exceptions and nonlocal exits. Cleanup errors raise `CleanupError` when there is no primary exception. With a primary exception, preserve it and append cleanup failures to the Session's `cleanup_errors`. Ordinary cleanup failures never replace the primary exception.

Only one dialogue, command, interaction or multi-session wait may own a session at a time. Competing operations raise `BusySessionError`, rather than queueing or reading the same bytes. Action callbacks may write and inspect their own session. Nested `expect` or `interact` on the same session raises `ReentrancyError`; use continuation or a subsequent wait. Callbacks may operate on an independent session. This restriction intentionally narrows the backend's possible reentrancy behavior.

## 5. Patterns, precedence and buffer consumption

### 5.1 Pattern types

| Pattern | Meaning |
|---|---|
| String | Unanchored literal byte substring. `'.'` matches a dot. |
| Regexp | Ruby regular expression with ordinary Ruby anchoring and captures. |
| `:eof` | Stream EOF, after attempting text matches against remaining input. |
| `:timeout` | A time limit expires without a selected text/EOF outcome. |

Simple positional patterns and a declaration block cannot be mixed. A block offers `on(pattern, name: nil)`, `timeout { ... }`, `eof { ... }` and `use(rules)`. Names, when supplied, must be unique Symbols across the expanded declaration. Exactly one timeout handler and one EOF handler per source are allowed. Literal strings such as `'EOF'` remain ordinary text.

An `on` clause has exactly one String or Regexp. Empty strings and regex matches of zero bytes raise `EmptyMatchError`; failing regex matches are not rejected simply because the regex could match an empty string in a different context. Globbing is not inferred from strings.

### 5.2 Selection rule

Each pass scans the current buffer against rules in declaration order; **the first declared rule that can match wins**, even if another rule matches earlier in the text. The earliest occurrence for the winning rule is selected using that rule's native matching semantics. Priority concerns currently available bytes; the engine cannot wait for an unknown future completion of a higher-priority pattern.

No automatic EOL, password, paging or prompt rules take precedence over declared patterns. Bytes need not contain newlines, and multiline expressions see the entire unmatched buffer.

### 5.3 Exact consumption example

Given buffer `notice: abcREADYtail` and winning literal `READY`:

| Result field | Value |
|---|---|
| `before` | `notice: abc` |
| `match` | `READY` |
| `after` | `tail` |
| Next session buffer, `consume: true` | `tail` |
| Next session buffer, `consume: false` | `notice: abcREADYtail` |

All consumption and Result construction finish before the action runs. `after` is a snapshot, not a live buffer reference. Unread kernel bytes are not represented in `after`. A subsequent wait may immediately match retained input.

`consume: false` is an inspection operation: `exp_continue` is forbidden for that wait and raises `InvalidContinuation`. A caller may deliberately repeat a non-consuming wait later. This explicit restriction prevents accidental no-progress callback loops.

## 6. Results and errors

A frozen `Expect4r::Result` has the following fields. Text snapshots and capture containers are frozen copies; the referenced session remains live.

| Field | Contract |
|---|---|
| `status` | `:matched`, `:timeout` or `:eof`. |
| `name` | Declared Symbol for a text match, otherwise nil. |
| `pattern_index` | Zero-based index in expanded text-pattern declarations, otherwise nil; events do not take indices. |
| `pattern` | A snapshot of the winning String/Regexp, otherwise nil. |
| `session` | Source Session; nil for aggregate timeout in a multi-session wait. |
| `before` | Bytes preceding a text match, or remaining input on single-session timeout/EOF. |
| `match` | Matched byte string, or nil. |
| `after` | Buffered suffix for a text match, otherwise nil. |
| `captures` | Regex capture values, including nil for unmatched groups; [] for literals and events. |
| `reason` | `:timeout`, `:idle_timeout`, `:total_timeout`, or nil. |
| `elapsed` | Monotonic seconds since entry to the overall call, including prior continuations. |
| `pending` | Frozen map of Session => remaining-byte snapshot on aggregate timeout; otherwise {}. |

Predicates: `matched?`, `timeout?`, `eof?`. `to_h` returns field data. `inspect` and `to_s` omit received text, secrets and exception messages. Pattern indices are convenience metadata; names are preferred for application logic.

`expect` returns event outcomes without raising. Parameter, encoding, transport and user callback errors raise directly. A successful match does not imply a successful remote operation. An authentication error or device syntax error can itself be a matched pattern.

`expect!` raises `ExpectTimeout` or `UnexpectedEOF` for the final event outcome, with `result` attached, unless that event was explicitly requested using a positional symbol or registered handler. Therefore `expect!(:eof)` is successful, as is an explicitly handled EOF. Registering a timeout handler acknowledges that outcome; the handler can raise its own application error. Handler return values remain ignored.

All library errors have useful standard `message` values and preserved causes. Error families: `SpawnError`, `TransportError`, `WriteTimeout` (with `bytes_written`), `BufferOverflow`, `EncodingError`, `ExpectTimeout`, `UnexpectedEOF`, `BusySessionError`, `ReentrancyError`, `InvalidContinuation`, `EmptyMatchError`, `ResponseLimitError`, `CleanupError`, `UnsupportedOperation`. Parameter validation uses Ruby's `ArgumentError`/`TypeError` where appropriate.

## 7. Time limits and continuation

Three independent monotonic budgets are available:

| Option | Starts | Resets |
|---|---|---|
| `timeout` | On call entry | Explicit `exp_continue(reset_timeout: true)` only. Incoming bytes do not reset it. |
| `idle_timeout` | On call entry | Each nonempty receive, and explicit reset continuation. |
| `total_timeout` | On call entry | Never. Caps the complete dialogue including continuations. |

The earliest active expiration wins. Simultaneous expirations use total, timeout, idle priority for `reason`. A normal match ends the wait unless its action continues. `exp_continue` defaults to resetting the relative timeout and idle budgets, preserving Tcl-style dialogue ergonomics. `reset_timeout: false` preserves their current deadlines. The total deadline remains fixed in both cases.

```ruby
result = session.expect(timeout: 10, idle_timeout: 3, total_timeout: 60) do
  on '--More--', name: :page do
    write ' '
    exp_continue(reset_timeout: false)
  end
  on /router#\s*\z/, name: :prompt
end
```

Here a page does not extend the ten-second operation budget. To allow ten seconds after each interaction while retaining a one-minute cap, use `exp_continue` without arguments.

`exp_continue` is nonlocal: statements after it in the action do not execute; Ruby `ensure` clauses do. It targets the innermost active wait for that session and is illegal outside an action. A timeout handler may continue a relative/idle timeout, but must request a reset; continuing an already-expired total deadline raises `InvalidContinuation`. EOF handlers cannot continue an exhausted source. Data must change or time must advance between continued timeout deliveries; zero-timeout repetition in one call is rejected.

On initial entry, already-buffered text is matched before an expired-budget outcome is delivered. If EOF is already known on entry, buffered text gets priority, then EOF, then timeout. After a continued action, an expired total budget takes precedence over another text action, including one matching retained bytes. On ordinary read passes, scan received text before relative/idle timeout delivery. After budgets expire, the engine does not perform another blocking read. `timeout: 0` gets its single readiness poll exception as defined above.

Budgets govern library waits and are checked between callbacks, reads, writes and matching passes. The engine does not asynchronously kill a callback or interrupt arbitrary application code. Slow callbacks can overrun a deadline; after callback return the engine honors the expired total budget before reading more input. A synchronous write uses the smaller of its own timeout and the remaining active dialogue budget; partial delivery is reported and never retried automatically. Ruby per-Regexp timeouts can bound expensive regex evaluation without modifying global regex settings.

## 8. Bytes, buffering and streaming

Buffers and Result text preserve raw bytes. No automatic newline conversion, ANSI stripping, echo removal or whitespace normalization occurs in the core. PTY terminal settings can themselves transform child output; tests account for this separately.

Literal patterns compare bytes. Binary regexes operate on bytes. Fixed-encoding text regexes support split UTF-8 characters: retain a valid incomplete trailing character and wait for completion. Invalid byte sequences, or incomplete text at EOF with a relevant text regex, raise `EncodingError`. Capture values preserve matched bytes. Presentation code explicitly decodes copies for display.

The default unmatched-buffer limit is 1 MiB; `nil` explicitly opts into unlimited buffering. `buffer_limit` bounds unmatched data, not the total output of a dialogue. Overflow raises `BufferOverflow` without silently trimming older input. The error exposes the retained buffer and the rejected read chunk; the session is marked failed for matching until explicitly cleared. A read chunk is at most 64 KiB, so error capture is also bounded. Explicit clearing discards those rejected bytes as well; a caller needing them retrieves them from the exception first. This recovery policy is part of the public contract.

Large outputs should be streamed or consumed using explicit rules. No hidden search window may make matches miss earlier bytes. Internal optimizations must preserve declared regex and literal semantics.

```ruby
File.open('received.log', 'wb') do |log|
  Expect4r.spawn('long-running-tool', transcript: log) do |session|
    session.expect!(timeout: 60) do
      # The completion clause has explicit priority over the general line rule.
      on "DONE\r\n", name: :done do |event|
        event.before.each_line { |line| process_line(line) }
      end
      on /[^\n]*\n/n, name: :line do |event|
        process_line(event.before + event.match)
        exp_continue(reset_timeout: false)
      end
    end
  end
end
```

A transcript is a borrowed writer and records each received byte once, including bytes consumed by intermediate rules. It does not contain transmitted bytes. Core Result#before contains only input since the last consumed match; it is not an accumulated command transcript.

## 9. Writing, diagnostics and secrets

`write` finishes the complete byte string or raises; `send_line` appends exactly one chosen terminator, even if the supplied text already ends with it. For exact-byte behavior use `write`. No output is sent merely because a callback returns a String. Partial writes and backpressure are handled without duplicating accepted prefixes. `WriteTimeout#bytes_written` covers this call's confirmed bytes, including a partially written line terminator. Reconnection never retries a write.

`logger` accepts a standard Ruby Logger-compatible object; it defaults to nil. Metadata-only logging is the default. Byte-level diagnostics require explicit opt-in through `session.trace_bytes = true`.

`session.redact(*secrets)` registers literal byte sequences for streaming filtering in diagnostics and receive transcripts. `sensitive: true` registers the complete outgoing text before any byte is sent and suppresses its outgoing byte trace. Redaction must span read boundaries and handle an incomplete secret prefix at transcript close conservatively. Match input, Result fields and explicit user outputs remain raw. Echoed secrets are filtered from diagnostics/transcripts after registration. User-written result logging remains the caller's responsibility.

No reversible built-in password-storage cipher is provided. Passwords can be supplied by a lazy credential provider in the router layer. The library does not promise to erase all Ruby String copies from memory.

## 10. EOF, process status and cleanup

`eof?`, `closed?` and `process_status` are distinct facts. After a PTY EIO indicating terminal EOF, normalize that event into EOF; other EIO contexts retain their transport error. EOF never implies exit status zero, and does not itself signal the child.

A text match can still succeed against buffered output after the input stream closes. Once no text clause matches, EOF produces one Result containing all remaining input in `before` and consumes that remainder. Subsequent waits return EOF immediately with empty `before`, without polling loops.

`wait(timeout:)` only observes/reaps the direct child. It does not consume input; callers normally drain to EOF first to avoid blocking a verbose child on full output buffers. Timeout returns nil and leaves the session usable. Already-reaped status is returned on later waits.

`close` closes owned descriptors, observes exit, sends TERM if necessary, waits up to `grace`, then sends KILL if necessary and waits up to `kill_after`. It is idempotent and returns the known Process::Status or nil for a borrowed session. An owned child that cannot be confirmed reaped within the budget produces `CleanupError`; its PID remains available for diagnosis and a later cleanup attempt. The implementation must retain reaping responsibility through a bounded, explicit cleanup mechanism even after returning an error. It may not abandon a child to a killed waiter thread.

Direct-child ownership does not promise to terminate an entire remote job or arbitrary descendants. Graceful application logout is an explicit scripted action before close. No global signal handlers are installed.

## 11. Human interaction

```ruby
result = session.interact(escape: "\x14") # Ctrl-T returns to the Ruby script.
puts result.reason                       # :escape, :eof, :timeout or :input_eof
session.send_line 'show version'
```

Forward pending buffered bytes once before newly received bytes. Recognize a nonempty literal escape byte sequence across input-read boundaries and withhold the escape sequence itself from the child; bytes typed after it remain available through `InteractionResult#pending_input`. The caller retains that remainder for its next higher-level interaction; no terminal pushback is assumed. The default Ctrl-T is conventional for this project.

For a TTY input, `raw: true` saves and restores its complete terminal mode, including on exception. For pipe/file input, raw mode is skipped. Input EOF returns `:input_eof`; it does not close the child automatically. Timeout measures total interaction duration and defaults to nil. Window size is copied on entry where supported; automatic resize tracking is deferred. Interactive display is raw, so transcript redaction must not alter the bytes shown to the user.

`InteractionResult` contains `reason`, `session`, `elapsed` and frozen `pending_input`; failures raise directly. On timeout, input EOF or child EOF, pending input is empty. Terminal and read ownership are restored before returning or raising.

## 12. Reusable rules

```ruby
paging = Expect4r.rules do
  on '--More--', name: :page, limit: 100 do
    write ' '
    exp_continue(reset_timeout: false)
  end
end

result = session.expect(timeout: 30) do
  use paging
  on /router#\s*\z/, name: :prompt
end
```

`Expect4r.rules` returns an immutable reusable RuleSet. `use` expands rules at that declaration position; ordinary declaration precedence is unchanged. A RuleSet may contain text clauses only. Callbacks are attached to declarations; per-call counters and source state are independent across sessions and concurrent uses.

`limit` is a positive integer or nil and counts action executions per rule per call, across continuations. When exhausted, raise `ResponseLimitError` before consuming or responding to the next match. Rules have no implicit continuation or implicit reply behavior. Registration snapshots strings and arrays without freezing caller-owned values. A deliberately reused named rule cannot collide with another expanded name.

Reusable rules do not run in the background, register global handlers or consume bytes outside an active wait.

## 13. Multiple sessions

```ruby
result = Expect4r.expect(from: [router_a, router_b], timeout: 5) do |patterns|
  patterns.on(/alarm:/i, from: router_a, name: :alarm_a)
  patterns.on(/alarm:/i, from: router_b, name: :alarm_b)
  patterns.eof(from: router_a)
  patterns.eof(from: router_b)
end
puts result.session == router_a ? 'A' : 'B' if result.matched?
```

The module-level wait uses the same timeout, idle, total and consume options as a single-session wait. It acquires every listed session before reading any, and releases all ownership if acquisition fails. `from:` on a clause must identify a listed source; omission applies the clause to all listed sources.

Selection is rule order, then source-list order among sources with matching buffered input. Scan buffers before reading; perform fair bounded reads across ready sources and re-evaluate after each read round. Source-list order is a deterministic tie-break, not a claim about arrival time across machines.

Any selected EOF returns for that source, even if other sources remain open. The caller removes exhausted sources for subsequent waits. Aggregate timeout has `session: nil`, `before: ''` and `pending` snapshots for every source; no input is consumed. Aggregate idle resets when any listed source receives bytes. The relative and total budgets apply to the entire call. Aggregate timeout callbacks receive the same Result but execute with `self` set to a WaitContext, exposing frozen `sessions` and `exp_continue(reset_timeout: true)`. Its continuation obeys the same expired-total and no-progress restrictions. Text/EOF actions execute in their source Session. `Expect4r.exp_continue` is not a global API: within a text action use the source session's `exp_continue`, which resumes the aggregate wait.

## 14. Router layer

The core remains usable without loading vendor adapters. A router wraps a Session and uses only the public dialogue API.

```ruby
require 'expect4r_routers'

Expect4rRouters.open(:ios, host: 'lab-router', user: 'lab',
                      password: -> { ENV.fetch('ROUTER_PASSWORD') },
                      ssh: { host_key_policy: :strict }) do |router|
  result = router.exec('show version', timeout: 15)
  puts result.output
  raise result.error.message unless result.success?
end
```

`Router.open` starts SSH, performs the adapter's login dialogue, establishes a device-specific prompt, disables paging when supported, and cleans up on all paths. Strict host-key verification is the default; unknown/changed keys fail through SSH. No automatic acceptance rule is installed. Host, user, port and supported SSH settings become separate argv values. Telnet and jump-host configuration are later transport options; a general session can already run their executables explicitly.

Authentication has a bounded attempt count, default 3, and a total login timeout, default 30 seconds. Credential providers are called only after a password challenge and registered for redaction before sending. Password values are not serialized into public session descriptions. Key-only login needs no provider. Failure raises `AuthenticationError` or a specific host-key/connection error, rather than entering a generic prompt loop.

### 14.1 Commands and output

`router.exec(command, timeout: 30, idle_timeout: nil, total_timeout: nil, output: nil)` accepts exactly one String command. Embedded CR or LF is rejected before sending. It returns CommandResult for success, recognized device error, timeout or EOF. `exec!` raises CommandError, CommandTimeout or ConnectionLost for a non-success result and attaches it. `exec_many(array, ...)` returns results in input order and stops on the first non-success; `exec_many!` raises with the completed results attached. It never silently splits a String into commands.

CommandResult fields: `command`, `status` (`:ok`, `:device_error`, `:timeout`, `:eof`), `output`, `prompt`, `duration`, `mode_before`, `mode_after`, `error`, `output_bytes`, `truncated` (always false in this contract). `success?` is true only for `:ok`. Output is one byte String, with echoed command, paging markers and terminal prompt excluded according to the adapter's tested policy. Blank lines and interior whitespace are preserved. Do not strip an initial line merely because it resembles an echo unless the adapter has established echo behavior.

Each command owns an accumulator or streaming sink spanning every intermediate match. Final `Result#before` alone is insufficient after paging. With no sink, a configurable command capture limit defaults to 8 MiB; exceedance raises `OutputLimitError` with partial capture and marks command state uncertain. With `output:` as a borrowed writer, decoded output segments stream once, `CommandResult#output` is nil, and `output_bytes` tracks bytes delivered. No full duplicate capture is retained. Sink exceptions propagate with command progress and mark state uncertain.

Prompt matching uses explicit adapter patterns learned from login and escaped hostname components. A bare universal `[>#]` suffix is insufficient. An explicit prompt override is supported for unusual devices. Asynchronous banners are ordinary output unless an adapter defines an explicit tested policy for them. Prompt detection has no hidden quiet-period heuristic.

After timeout, EOF, overflow or transport failure, mark the router `:uncertain`; reject subsequent exec/config operations until explicit `resynchronize!` succeeds or the connection is reopened. Resynchronization uses an adapter-defined cancel/interrupt sequence before a harmless prompt probe, and has a bounded timeout. If an adapter cannot establish a safe recovery sequence, resynchronization fails and the caller must reopen the connection. Recognizing the prompt does not establish the failed command's execution outcome. It never repeats the failed command or implies that it was not executed. `CommandTimeout` carries bytes sent and partial output. Generic automatic command replay is disabled.

### 14.2 Configuration and commit

```ruby
Expect4rRouters.open(:junos, host: 'lab-router', user: 'lab') do |router|
  router.configure do |config|
    config.command 'set interfaces lo0 unit 0 description "managed by Ruby"'
    config.commit
  end
end
```

The block enters and owns a configuration scope. `config.command` is the bang form of command execution inside that scope: a recognized device error raises immediately. The scope returns a ConfigurationResult with executed command results, commit result and final mode. No automatic commit is performed.

| Adapter capability | Successful exit without commit | Failure during block |
|---|---|---|
| Candidate configuration, with exclusive ownership acquired | Discard this scope's pending changes, then restore prior mode. | Attempt discard and prior-mode restoration; retain the primary error. |
| Immediate configuration, e.g. IOS | Keep already-applied commands and restore prior mode. | Report already-applied commands, restore mode if possible; no implied rollback. |

Candidate editing requires an adapter-supported exclusive configuration lock or equivalent scope ownership. Failure to acquire it aborts before edits; never discard somebody else's preexisting candidate. `commit` is supported only when the adapter advertises `candidate_config?`; otherwise raise `UnsupportedOperation` before sending. Once a commit succeeds, later scope failure cannot undo it implicitly. Commit failure is a structured error with device output. Cleanup failure marks mode uncertain and is attached without hiding the original error.

`router.mode`, `router.capabilities`, `router.resynchronize!` and `router.close` are public. V2.0 has one fully tested IOS adapter; IOS-XR and Junos follow once their configuration ownership and commit scenarios have fixtures. The example defines the Junos contract, not an assertion that the first milestone implements it.

## 15. Mapping to expect-pty

Proposed implementation candidate: `expect-pty` 0.10.1, evaluated at source revision `8303e641d247fffeed693b15fb9dee45a69d262d`. This is a candidate dependency, not an installed dependency of this checkout. Its published minimum is Ruby 4.0.6. The functional contract above takes precedence over convenient backend defaults.

| Requirement | Existing backend foundation | expect4r responsibility / validation |
|---|---|---|
| PTY spawn, borrowed IO, child cleanup | Session factories and lifecycle methods | Ownership contract, finite defaults, normalized errors and cleanup reporting. |
| Ordered text patterns and results | Matcher, PatternList, Result | Names, zero-based indices, uniform Result callbacks and event acknowledgement in bang methods. |
| Continuation | `Expect.continue(reset_timeout:)` token | Nonlocal `exp_continue`, contextual validity checks and per-call limits. |
| Total deadlines | `deadline:` monotonic absolute limit | Relative `total_timeout` conversion, explicit idle budget and expiration reason. |
| Buffer bounds | Tail-trimming `buffer_limit` | **Gap:** preserve input and raise on overflow; backend default trimming cannot satisfy the contract. |
| Reusable responses | Responder has different ordering and accumulation behavior | Implement ordered RuleSet expansion; do not silently substitute Responder precedence. |
| Encoding and logging | Byte handling, redactor, logger, transcript | Default metadata-only policy, sensitive send registration and preserved snapshots. |
| Multi-session waits / interaction | Existing capabilities | Narrow reentrancy, fairness, pending input and terminal restoration tests. |
| Router commands and configuration | No vendor abstraction | Implement adapters, output capture, recovery state and commit ownership. |

The overflow contract, deadlines and lifecycle must be checked against the exact release rather than assumed satisfied. If the backend cannot expose the necessary hooks without depending on private internals, prefer a small upstream change or maintained fork over a façade that falsely claims these guarantees. A new in-house engine remains a fallback after this evaluation.

## 16. Milestones and feature boundaries

| Milestone | Deliverable | Exit criteria |
|---|---|---|
| A — contract proof | Backend adapter spike and conformance harness | Matching, suffix preservation, EOF, deadlines, overflow and cleanup pass on Ruby 4.0.6+ Linux and macOS. |
| B — general-purpose core | Spawn/open, writes, both expect forms, results, continuation, RuleSets, logging and interaction | All core scenarios below pass; standalone scripts work without router code. |
| C — orchestration | Multi-session waits and one IOS adapter with simulator | Fairness, paging, command capture and recovery tests pass. |
| D — device expansion | IOS-XR/Junos configuration workflows and selected legacy adapter | Real-device checks plus candidate ownership/error fixtures; migration guide. |

Deferred capabilities: Tcl glob syntax, Tcl-specific regex anchors, background expect dispatch, implicit before/after rules, a CLI script interpreter, Windows PTY support, advanced interact regex filtering, arbitrary IO forwarding graphs, automatic window-resize propagation, automatic reconnect/replay, device-specific ping parsers and implicit proxy-session sharing. Explicit rules, Ruby control flow and SSH configuration cover several of these use cases already. Additions require their own contract and tests.

## 17. Required acceptance scenarios

| ID | Scenario | Required result |
|---|---|---|
| P01 | Literal prompt with no newline, split across reads | Matches once; correct before/match/after. |
| P02 | Regex spans multiple CRLF lines | Complete multiline match, with captures. |
| P03 | Literal metacharacters and prefixed text | Literal substring behavior; prefix retained in Result. |
| P04 | Two patterns match, second starts earlier | First declared matching rule wins. |
| P05 | A match leaves a second prompt buffered | Second wait returns without another read. |
| P06 | Empty-string / zero-width match action | EmptyMatchError, no callback or consumption. |
| P07 | Non-consuming wait followed by continuation | InvalidContinuation; buffer retained. |
| P08 | Registration raises or has duplicate names | No input consumed or child response sent. |
| T01 | Trickle output with timeout 0.1 seconds | Timeout is not extended by reads; tolerance excludes scheduling/regex/callback overruns. |
| T02 | Continue with and without timer reset | Relative deadline changes exactly as specified; total deadline stays fixed. |
| T03 | Silent child / idle timeout | Correct timeout reason and retained buffer. |
| T04 | Repeating timeout handler / exhausted total budget | No hot loop; total-budget continuation rejected. |
| T05 | Buffered match and known EOF/expired timer | Text match, then EOF on next wait. |
| E01 | EOF with unmatched partial bytes on pipe and PTY | EOF Result contains remainder; no spin. |
| E02 | Immediate child exit / failed exec | Output and exit status recoverable / SpawnError without leaks. |
| E03 | expect!(:eof) and registered timeout handler | Acknowledged events return Results; unhandled events raise. |
| B01 | Split UTF-8 / invalid bytes / binary regex | Valid fragments assemble; explicit encoding failures; binary remains byte-exact. |
| B02 | Buffer at limit, then overflow | No silent trimming; retained and rejected bytes recoverable. |
| W01 | Partial write, backpressure, expiry | Correct bytes_written; no duplicated prefix or automatic replay. |
| L01 | Callback exception / nonlocal return / stubborn child | Original control flow preserved; bounded descriptor and child cleanup. |
| L02 | Borrowed versus owned socket | Correct close responsibility; no signals for unowned process. |
| L03 | Concurrent operations / same-session nested wait | BusySessionError / ReentrancyError before extra reads. |
| S01 | Sensitive echo split across reads | Diagnostics/transcript redact it; matcher still sees original bytes. |
| I01 | Interaction escape split across input reads | Escape withheld, remainder returned, terminal restored. |
| M01 | Two ready sources / one source EOF | Deterministic precedence, fair reads, correct source ownership. |
| R01 | Login prompt, key auth, bad password, changed host key | Bounded attempts and specific outcomes; no generic acceptance. |
| R02 | Paging and repeated confirmations | Response limits enforced; full command output retained once. |
| R03 | Quoted whitespace / blank output lines | No command rewriting; output fidelity follows adapter echo policy. |
| R04 | Command timeout after possible remote execution | State uncertain; no replay; explicit recovery required. |
| R05 | Candidate lock, failed command/commit, immediate IOS writes | Correct ownership, cleanup and already-applied command reporting. |

Use a local child-process simulator, deterministic pipes/socket pairs and injected clocks where appropriate. PTY tests remain real PTY tests; do not replace lifecycle or terminal-restoration checks with mocks. Keep timing tolerances explicit. Native Linux and macOS checks are required because PTY EOF and terminal behavior differ. Manual real-router checks complement automated fixtures.

## 18. Review defaults

The following are concrete proposals, ready to change if usage shows a better choice:

- `expect` returns structured events; `expect!` rejects unacknowledged timeout/EOF.
- Every action receives one Result; source actions run in their session context, aggregate timeouts in a WaitContext.
- Declared pattern priority is consistent across simple waits and reusable rules.
- `exp_continue` resets the relative timer by default; total_timeout provides an independent cap.
- Buffers fail visibly on overflow; they never silently discard match input.
- Command capture spans all intermediate responses; explicit sinks support large outputs.
- Router configuration never commits implicitly, and reconnect never replays commands implicitly.
- One general-purpose core is used by login, commands, paging and adapters.

Sources: [initial assessment](../ASSESSMENT.md), [Tcl/Expect reference](https://core.tcl-lang.org/expect/doc/trunk/expect.man), [expect-pty source](https://github.com/gatework/expect-ruby), [backend API](https://github.com/gatework/expect-ruby/blob/8303e641d247fffeed693b15fb9dee45a69d262d/docs/API.md), [backend compatibility boundaries](https://github.com/gatework/expect-ruby/blob/8303e641d247fffeed693b15fb9dee45a69d262d/docs/COMPATIBILITY.md), [published 0.10.1 requirements](https://rubygems.org/api/v2/rubygems/expect-pty/versions/0.10.1.json).

## Implemented extensions: diagnostics and buffer recovery

The original API tables above are extended by [scoped diagnostics and the phased
design](DEBUGGING_AND_BUFFERING.md), [recording/history](RECORDING_FORMAT.md), and
[P4 buffer recovery](BUFFER_RECOVERY.md). The recovery extension adds the
`full_buffer` action, `:full_buffer` result status, `Result#staged`, `consume_buffer`,
`resize_buffer`, `buffer_ceiling`, and staged-byte inspection. Default overflow
behavior is unchanged; incremental staging is opt-in through a recovery handler
and is also used while forwarding manual interaction.

P5 adds [streaming capture](STREAMING_CAPTURE.md): `Expect4r::Capture`,
`Session#capture_until`/`capture_until!`, bounded retained output, independent total
limits, declared regex context, and sink errors with confirmed progress. Router
output storage now shares the core writer; vendor framing remains in the application.

P6 adds [offline replay](REPLAY.md): `Expect4r.replay`, strict `ReplayTrace` loading,
fragmentation and scaled timing, explicit redacted-span substitutions, transport-error
injection, and `Session#verify_replay!`. The factory performs close-time verification
and owns its local pipe/timer resources.
