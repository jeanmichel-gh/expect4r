# Debugging, buffering and dialogue replay

Status: P1–P6 implemented locally on 2026-11-13; development APIs remain under review.
Design baseline: commit `875ecd0`.
Audience: expect4r maintainers and application authors. P1 events, P2 debugging, P3 recording/history, P4 recovery, P5 capture and P6 replay are available in this checkout.
Other new APIs below remain proposals.

## Goal and scope

Make it possible to explain a failed dialogue, handle large output deliberately,
and reproduce failures without the original device. These facilities belong in
the generic expect4r core. Router adapters may supply labels or application events,
but vendor prompts, modes and commands remain in `expect4r-routers`.

Retain `interact` as a first-class operation: automated waits, manual control and
return to automation must be diagnosable through the same session event stream.
This plan does not replace Ruby's debugger or promise complete Tcl/Expect parity.

## P1 usage and validation

```ruby
require 'expect4r'
require 'json'

# The callback receives frozen metadata Hashes; no protocol payload or pattern text.
sink = ->(event) { $stderr.puts(JSON.generate(event)) }
Expect4r.spawn('ssh', 'lab-router', diagnostics: sink, label: 'lab') do |session|
  session.expect!(timeout: 10) do
    on /[Pp]assword: ?\z/, name: :password do
      send_line ENV.fetch('ROUTER_PASSWORD'), sensitive: true
      exp_continue
    end
    on /router#\z/, name: :ready
  end
end
```

P1 emits `wait_start`, `rule_registered`, `rule_attempt`, `rule_error`, `match`,
`consume`, `buffer_clear`, `receive`, `write_progress`, `write_timeout`,
`deadlines`, `continuation`, `timeout`, `eof`, `overflow`, `wait_result`,
`wait_error`, `registration_error`, `interaction_start`, `interaction_end`, and
`cleanup_error`. Events include schema version 1, process-local session ID,
optional label, per-session sequence and monotonic timestamp. Events within a wait
share its process-local wait ID across sources. Constructor registration failures
use `registration_wait_id` because ownership has not yet been acquired.

Match offsets are zero-based byte ranges with exclusive end offsets. Consumption
advances the buffer origin, including output consumed by `interact`. Clearing an
overflowed buffer advances past the already-read rejected bytes as well. Receive
events report the chunk size, its stream offset, and bytes retained at emission.
Write progress is confirmed per partial write. Aggregate results identify the
selected source. Trace payload excludes patterns, exception messages, raw buffers,
captures and credentials; caller-supplied labels and rule names should be safe to
export. Existing logger, transcript and byte-tracing APIs remain unchanged.

Callbacks execute synchronously and must not read/mutate the session or block
indefinitely. A failing sink is disabled and its exception propagates during
ordinary operations; reporting an existing error preserves that primary error
and stores secondary diagnostic failures in `cleanup_errors`. Diagnostic sink
failure during receive retains the read bytes in the unmatched buffer.

Native macOS ARM64, `rv` Ruby 4.0.9: 55 core tests/222 assertions, 27 router
tests/254 assertions, and 20 legacy tests/68 assertions passed. Both gems built
and passed isolated installation/dialogue checks. No Linux claim for P1 yet.
A small local socket-pair check (median of three, 2,000 literal waits) measured
0.0152 seconds disabled and 0.0231 seconds with a counting metadata callback.
This illustrates event overhead; it is not a production throughput or memory
benchmark and does not compare disabled tracing against the pre-P1 code.

P1 deliberately shipped metadata only. P2 adds the scoped formatter below;
The subsequent phases now add recording/history, recovery, streaming capture and replay.

## P2 scoped debugging

```ruby
session.with_debug(output: $stderr, level: :matching) do
  session.expect!(/ready>\z/)
end

# Explicitly request bounded, escaped byte previews.
session.with_debug(output: $stderr, bytes: true, preview_limit: 128) do
  session.expect!(/ready>\z/, timeout: 5)
end

# Hex previews for binary protocols.
File.open('debug.log', 'w') do |file|
  session.with_debug(output: file, bytes: true, format: :hex) do
    session.expect!("\x00\xff".b)
  end
end
```

The caller owns output handles and must close them; a block-owned File can also
wrap `with_debug`. The scope returns the block's value. Normal exit, exceptions
and nonlocal return restore the previous debug sink; nested scopes temporarily
replace the outer formatter. Other threads cannot use the session while the scope
holds its lease. A scope is entered around operations, not from a running wait's
action. Existing `logger:`, `trace_bytes` and metadata callbacks are independent.

Options:

| Option | Values and behavior |
|---|---|
| `level:` | `:matching` (default) includes rule registration/attempts; `:events` omits those two noisy event types |
| `output:` | Writable sink, default `$stderr`; partial writes are handled |
| `bytes:` | `false` by default; `true` enables byte previews |
| `format:` | `:escaped` (default, Ruby byte-string escapes) or `:hex` |
| `preview_limit:` | Positive byte count, default 256; displays the tail and reports omitted bytes |

The formatter preserves P1 session/wait IDs, sequence numbers, labels and monotonic
timestamps. Metadata callbacks continue to receive metadata only, even when byte
previews are enabled. Snapshot blocks are not evaluated when previews are off.
Pattern text, captured values and exception messages are not printed.

RX/TX `byte_preview` events use continuously maintained streaming redaction before
formatting or truncation. Incoming chunks and confirmed outgoing partial writes
are filtered independently. A secret prefix can remain withheld until subsequent
bytes disambiguate it; this is a diagnostic view, not an exact wire recording.
Redaction state remains continuous across nested scopes and periods without debug
output, for sessions with registered secrets. As before, secrets must be registered
before receipt/transmission, either through `redact` or sensitive sends.

Rule-attempt and timeout snapshots are conservatively suppressed once any secret
has been registered. Re-reading a consumed buffer cannot safely establish whether
its leading bytes are the middle of a secret. Sanitized RX/TX previews remain
available. This policy prevents fragments leaking through snapshots; richer
snapshot redaction is deferred to P3. Raw results and manual terminal display are
unchanged. User labels and rule names must be appropriate for export.

A failed formatter disables itself and propagates the sink error during normal
operations; primary errors retain precedence during error/cleanup reporting.
The previous scoped formatter is restored on exit. P2 passed 66 core tests/275
assertions, 27 router tests/254 assertions, and 20 legacy tests/68 assertions on
native macOS with rv Ruby 4.0.9; both built gems passed isolated installation checks.
No automatic file rotation,
recording, live-display toggle or replay is added in P2.


## P3 recording and history

See [the usage guide and version 1 format](RECORDING_FORMAT.md) for `recording:`,
`history:`, binary payloads, original IO timestamps/ranges, length-preserving secret
masks, bounded history, completion semantics and sink-failure behavior. Redacted
recordings require explicit substitutions in the P6 replay API.
P3 also corrects outgoing Logger redaction across separate write calls.

## P4 buffer recovery

See [buffer recovery](BUFFER_RECOVERY.md) for the implemented `full_buffer` DSL,
`consume_buffer`, `resize_buffer`, `buffer_ceiling`, immutable staged snapshots,
precedence and failure behavior. Recovery is opt-in; legacy overflow behavior remains
the default. P5 capture and P6 replay build on this foundation.

## P5 generic streaming capture

See [streaming capture](STREAMING_CAPTURE.md) for `Capture`, `capture_until` and its
bang form, independent retention/total limits, declared regex windows, byte-safe
prefixes, and confirmed sink-failure progress. The router application now shares
the generic writer while retaining vendor framing/prompt policies. P6 replay is also implemented.

## P6 offline replay

See [offline replay](REPLAY.md) for strict recording validation, queued input,
outgoing-byte verification, alternate fragmentation, explicit secret substitutions,
scaled timing, injected transport failures and close-time verification. Fixture
inspection and a record/replay PTY example are included. One-byte router replay also
fixed fragmented pager-space handling while preserving real indentation.

## Baseline before P1

| Capability | Current behavior | Limitation |
|---|---|---|
| Logging | Per-session `logger:` with basic write events | No matcher decision trace or stable event schema |
| Byte tracing | `trace_bytes = true` emits RX/TX DEBUG messages | No session/wait IDs, offsets, timestamps or scoped tracing |
| Transcript | `transcript:` writable sink receives incoming bytes | Incoming only; not a bidirectional recording |
| Redaction | `sensitive: true` and `redact` register literal secrets; incoming filtering spans chunks | Results and explicit terminal output remain raw; not a general sensitive-data detector |
| Buffer | Immutable `buffer` snapshot; `clear_buffer` returns removed bytes | No public selective consumption or resumable overflow |
| Limits | Default 1 MiB per session; positive size or `nil` at creation | Unlimited mode can exhaust memory; no runtime resizing |
| Overflow | `BufferOverflow` exposes retained/rejected bytes; session matching fails until cleared | Caller must preserve/reconcile rejected bytes; no full-buffer callback |
| Matching | Ordered literal/regexp rules across reads; suffix retained | No explanation of tested rules or byte consumption |
| Results | Immutable before/match/after/captures, elapsed time and timeout reason | No absolute stream offsets or diagnostic history |
| Inspection | `consume: false` allows non-consuming text matches | Not a general buffer editing interface |
| Large output | Router capture can stream to an output sink while consuming lines | Not a generic core facility; individual lines still must fit |
| Manual interaction | `interact` forwards terminal IO; Ctrl-T returns; terminal settings restored | No structured handoff trace or full ongoing window-resize policy |

Source locations: `lib/expect4r/session.rb`, `wait.rb`, `patterns.rb`, `result.rb`,
`diagnostics.rb` and `interaction.rb`; router capture lives in
`applications/routers/lib/expect4r_routers/router.rb`.

There are several buffers to distinguish: the child's stdio buffer, kernel/PTY
queues, expect4r's unmatched bytes, application output capture, and recording or
history buffers. Increasing expect4r's limit cannot force a child to flush stdio.
Diagnostics should make that distinction explicit.

## Tcl/Expect reference points

The [official Expect manual](https://core.tcl-lang.org/expect/doc/trunk/expect.man)
is the comparison reference:

| Tcl/Expect | Proposed expect4r direction |
|---|---|
| `exp_internal` | Explain reads, rule attempts, matches and buffer decisions |
| `log_file` and `log_user` | Independently configure recording and live display |
| `match_max` and `full_buffer` | Explicit matching capacity and recoverable capacity event |
| `-notransfer` | Existing `consume: false` for text matches |
| `expect_out` | Existing immutable result snapshots, extended with offsets |
| `remove_nulls` and `parity` | Preserve bytes by default; consider explicit transforms separately |

Adopt the useful capabilities without silently copying truncation or byte
normalization behavior. Ruby regexps cannot generally explain why a pattern
failed; diagnostics can show the pattern, exact input and outcome.

## Design

### 1. Structured events and matcher diagnostics

Create a single internal event emitter shared by sessions and waits. Assign stable
session IDs, wait IDs, per-session sequence numbers and monotonic timestamps.
Optional user labels must not require a router dependency. Wall-clock origin is
recording metadata; elapsed time and deadlines use the monotonic clock.

Events should cover wait registration, read/write progress, rule attempts,
match spans, consumption, continuation, deadline reset/expiry, EOF, overflow,
interaction entry/exit and cleanup failure. Multi-session waits retain one wait ID
and identify the selected source. A failed write reports confirmed partial bytes.

Use byte offsets in the incoming stream. Discarded/consumed prefixes advance the
buffer origin; redacted display lengths must never redefine protocol offsets.
Record relative, idle and total deadlines separately. A trace distinguishes a
registration/encoding error from a pattern that simply did not match.

Proposed user API:

```ruby
session.with_debug(level: :matching, output: $stderr) do
  session.expect!(timeout: 5) do
    on /router#\z/, name: :ready
  end
end
```

`with_debug` restores previous settings on exceptions and nonlocal exits.
Metadata-only tracing is the default; byte previews require an explicit option.
Readable formatting uses escaped CR/LF/NUL/ANSI bytes; optional hex formatting
supports binary protocols. Bound preview length and report omitted byte counts.

Example output with byte previews enabled:

```text
session=router1 wait=12 event=receive bytes=9 buffered=23
session=router1 wait=12 rule=ready matched=false
session=router1 wait=12 buffer_tail="router# \r\n"
session=router1 wait=12 event=timeout kind=idle elapsed=5.002
```

Do not run every regexp twice to generate diagnostics. Disabled tracing should
avoid preview construction and buffer copies. Named rules are preferred; pattern
text and caller locations can themselves contain secrets and need an explicit
exposure policy. Preserve existing `logger:`, `transcript:` and `trace_bytes`
behavior while adding the new interface.

### 2. Display, recording and bounded history

Keep three independent destinations: live terminal output, structured dialogue
recording, and internal diagnostics. Retain the incoming-only transcript API.
Introduce a versioned recording schema, initially JSON Lines, with RX/TX direction,
sequence, elapsed time, byte count, and lossless base64 payloads when permitted.
Record confirmed write progress, not just requested writes. Include backend/runtime
metadata and operation boundaries, without automatically recording credentials,
command arguments or environment variables.

Support bounded diagnostic history with explicit event-count and byte limits.
Timeout/overflow reports can reference this history without dumping an entire
session. This history is independent of matching capacity.

Redaction must occur before any diagnostic formatter or sink sees payloads.
Handle secrets across chunk boundaries and all payload views, including previews
and snapshots; test against leakage when the same bytes are represented several
ways. Do not log secret-bearing raw pattern text by default. Redaction can delay
emission of ambiguous tails; retain original timestamps/offsets and distinguish
redacted payloads from exact recordings. State clearly that literal redaction does
not discover arbitrary secrets and may require registration before first receipt.

Choose and document sink failure behavior. Proposed default: propagate recording
failures as today, preserve the primary error during cleanup, and never report a
recording as complete after a sink failure. Optional best-effort diagnostic sinks
must report dropped events. File rotation belongs to an explicit sink utility.

### 3. Recoverable buffer-full event

Retain `BufferOverflow` as the default when no handler is installed. Add a generic
full-buffer event whose action may consume/stream an explicit prefix, increase
capacity within a configured ceiling, or abort. The final DSL spelling is decided
in this phase; it must fit the existing pattern/action interface.

Required semantics:

- Try eligible text patterns before reporting full capacity. A match completed at
  the capacity boundary wins over a full-buffer event.
- Process received data incrementally so a large OS read containing several
  consumable messages does not overflow before matching has a chance to progress.
- Never lose the remainder of an already-read chunk, including on callback or sink
  failure. Account for this staging memory separately from matching capacity.
- A handler must free space or grow capacity; otherwise raise a progress error.
- Keep total deadlines active through handlers; continuation follows the same
  timer policy as ordinary actions. Define idle semantics for staged bytes.
- Preserve one-reader ownership and reject nested waits in callbacks.
- Specify EOF/timeout/full-buffer precedence, including non-consuming waits and
  multi-session waits. Do not silently discard data.
- Preserve the existing exception's retained/rejected byte accounting for callers
  that do not opt into recovery.

Dynamic resizing must reject a size below retained bytes unless consumption is
explicitly requested. Unlimited mode remains opt-in.

### 4. Generic streaming capture

Separate output retention from bytes needed for matching. Introduce capture to a
borrowed sink, with independent capture limits, optional bounded retained output,
and byte accounting. A sink failure must not falsely imply that output was saved.

Do not promise arbitrary regex matching with a fixed rolling suffix: an unbounded
regexp may require the entire stream. Streaming requires an explicit consumable
boundary, a protocol framing rule, or a declared finite matching window whose
limitations are visible. Discarding bytes remains an application decision.

Handle matches spanning reads, no-newline megabyte output, fragmented UTF-8,
NUL bytes and sink partial writes. Move reusable mechanics into core, then adapt
router capture without changing command output, paging or context semantics.
Avoid maintaining duplicate full-response copies.

### 5. Recording replay

Add a replay transport compatible with the generic reader/writer boundary. It
supplies RX bytes and EOF and verifies expected TX bytes without contacting a
router. Default replay ignores recorded timing for deterministic tests; optional
virtual timing or scaled timing exercises deadlines.

Recorded OS chunk boundaries are useful evidence, not a protocol contract. Replay
must support alternate fragmentation, including one byte at a time. Compare TX as
a byte stream rather than requiring the same sequence of write calls. Model
partial writes and errors explicitly where present.

A redacted recording is not an exact wire capture. Use declared secret placeholders
and caller-supplied substitutions or explicit wildcard expectations. Never silently
accept arbitrary outgoing bytes because a secret was redacted. Recordings with
missing/dropped events must fail strict replay or require an explicit partial mode.

## Implementation sequence

Each phase is a separate reviewable change. Do not ship all proposed interfaces
at once. Existing tests and behavior remain the regression baseline.

| Phase | Deliverable and main files | Acceptance criteria |
|---|---|---|
| P1 | Event schema/emitter and matcher trace; `diagnostics.rb`, `session.rb`, `wait.rb`, `interaction.rb` | Rule order, spans, consumption, timeout cause and manual handoff are visible; disabled tracing has no payload formatting; existing tests pass |
| P2 | Scoped debug API, renderers and correlated labels | Settings restore on normal/exception/nonlocal exit; escaped/hex binary output is bounded; session/wait IDs remain unambiguous across concurrent sessions |
| P3 | Versioned RX/TX recorder, redaction integration and bounded history | Confirmed partial writes and original offsets recorded; fragmented secrets absent from every exported view; sink failures and incomplete recordings identifiable |
| P4 | Incremental receive/match loop and full-buffer action | Boundary match wins; read remainder survives; no-progress actions rejected; default overflow compatibility and deadline behavior tested |
| P5 | Generic streaming capture and router migration | Large newline-free output has bounded memory under declared framing/window rules; exact output and paging tests pass; no vendor code added to core |
| P6 | Replay transport and fixture tools | A captured synthetic failure reproduces offline; fragmented replay yields same match results; TX mismatch reports first differing offset; placeholder policy enforced |

P1 precedes P2/P3; P4 depends on P1's buffer accounting; P5 depends on P4; P6
requires the stable P3 recording format. P1–P6 are implemented. Continue evaluating development APIs and event/schema
contracts before a public release; real-device and broader platform validation remain.

## Verification plan

Use deterministic socket pairs and controllable clocks where possible; use real
local PTYs for lifecycle, echo and `interact` terminal restoration. No routers are
required for this work. Keep the core-only package installation check.

Add focused tests for:

- Rule precedence, named rules, regexp encoding errors, continuation, aggregate
  waits, partial EOF, and each deadline's trace.
- Exact offsets before/after consumption; CR/LF, ANSI escapes, NUL, invalid UTF-8,
  multi-byte split characters, and bounded byte previews.
- Secrets fragmented across reads/writes, overlapping secrets, final tails,
  snapshots, sink errors, and explicit sensitive sends.
- Overflow at/below/above capacity, matching exactly at capacity, oversized reads,
  capacity growth, callback failure, stalled handlers and staged remainder.
- Streaming with very long lines, cross-chunk matches, slow/partial-write sinks,
  sink failures and configured output limits.
- Interaction enter/exit/escape/EOF/error events and terminal restoration;
  automated waits after returning from manual control.
- Replay alternate fragmentation, TX mismatch, timestamps, timeout simulation,
  secret substitution and truncated recordings.

Benchmark disabled tracing, metadata tracing and byte tracing separately for
sustained output, many patterns and concurrent sessions. Report throughput, peak
memory and event volume; choose budgets from the measured baseline before
acceptance, rather than claiming zero overhead. Test native macOS with `rv` and
Linux using the project's supported Ruby 4 versions.

## Decisions to resolve during implementation

1. Exact public debug/recording configuration and how existing Logger levels map.
2. Full-buffer DSL, buffer mutation API, staged-byte accounting and hard ceilings.
3. Finite-window/framing contract for streaming regex matching.
4. Recording payload/redaction metadata and strict replay substitution format.
5. Virtual clock integration for deterministic timeout replay.

Resolve these in the relevant phase with concrete examples and tests. Runtime
resizing, input transformations such as null stripping, automatic reconnect and a
custom Ruby debugger are not prerequisites for P1.
