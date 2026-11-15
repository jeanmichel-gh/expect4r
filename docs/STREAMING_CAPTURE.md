# Generic streaming capture

Implemented in P5, 2026-11-13. `Expect4r::Capture` provides reusable output accounting,
sink writes and retention; `Session#capture_until` integrates it with bounded
matching. Router policies remain in the separate application.

## Stream to a file with a bounded retained tail

```ruby
require 'expect4r'
require 'rbconfig'

File.open('output.bin', 'wb') do |file|
  Expect4r.spawn(RbConfig.ruby, '-e', 'STDOUT.write("x" * 300_000 + "DONE>")',
                 buffer_limit: 4096) do |session|
    result = session.capture_until!('DONE>', sink: file, retain: 1024,
                                   total_timeout: 30)
    puts result.output_bytes # 300000, excluding the terminator
    puts result.sink_bytes   # 300000, confirmed by the sink
    puts result.output.bytesize # 1024, the retained tail
    puts result.truncated    # true: the retained snapshot omits earlier bytes
  end
end
```

The sink receives the full captured response, not only the retained tail. The caller
owns, flushes and closes it. The matched terminator is consumed but excluded from
capture; it is available in `result.event.match`. Following bytes remain in the
Session's matching/staging buffers for the next operation. Capture does not remove
echo, normalize line endings, page output or infer terminal prompts.

## API and independent limits

```ruby
session.capture_until(pattern, sink: nil, retain: 65_536, limit: nil,
                      match_window: nil, timeout: session.timeout,
                      idle_timeout: nil, total_timeout: nil)
```

`capture_until` returns a `CaptureResult`. The bang version raises `ExpectTimeout`
or `UnexpectedEOF` for those statuses and attaches the CaptureResult as `error.result`.
Other errors, including sink and capture-limit failures, propagate in both forms.

| Field or option | Meaning |
|---|---|
| `status` | `:matched`, `:timeout` or `:eof` |
| `success?` | True only when the terminator matched |
| `output` | Frozen retained byte String, including partial output on timeout/EOF |
| `output_bytes` | Total bytes accepted by the capture |
| `sink_bytes` | Total bytes confirmed by the sink; zero without a sink |
| `truncated` | Retained output omits accepted bytes; does not imply the sink lost data |
| `event` | Underlying immutable Result, including timeout reason and staged snapshots |
| `retain:` | Default 65,536 bytes of tail; zero keeps no output; explicit nil retains everything |
| `limit:` | Independent total accepted-byte ceiling; nil means no total ceiling |
| Session `buffer_limit` | Finite matching capacity; independent of capture/retention limits |

A finite retained tail may begin in the middle of a UTF-8 character because output
is binary data. Decode it only with an explicit display policy. Explicit `retain: nil`
can grow memory with total output. A sink can also retain data internally; bounded
core matching/retention does not bound the sink's own storage.

Capture consumes accepted partial output on timeout/EOF; ordinary `expect` keeps
its existing consumption semantics. Already-read staged bytes not exposed to the
matcher remain uncaptured and are visible through `result.event.staged`. An EOF or
timeout result is not automatically replayed or retried.

## Matching contract

A nonempty literal terminator supplies its own finite context: the capture retains
at least `terminator.bytesize - 1` matching bytes at full-buffer boundaries. Thus a
literal can straddle physical reads and matching windows without being discarded.
The Session must have a finite `buffer_limit` covering the terminator length.

A regexp requires an explicit positive `match_window:` no larger than buffer capacity:

```ruby
result = session.capture_until!(/DONE:[0-9]{1,3}>/n, match_window: 9)
```

This is the caller's declaration of the maximum byte context needed for recognition,
including lookaround. It is not inferred or verified from Ruby regexp syntax.
Unbounded regexps cannot be guaranteed by a finite window. Absolute/line anchors
and lookbehind apply to the current retained buffer, not automatically to original
stream history. Use literal terminators or an explicitly understood framing rule
when those semantics would be ambiguous.

For fixed text encodings, discarded prefixes end at valid character boundaries.
The capture can retain additional bytes to avoid splitting a character. If the
buffer has no room to consume a complete character while preserving the declared
context, it raises `BufferProgressError`; increase `buffer_limit` rather than discard
necessary bytes. Invalid input for a text regexp still raises `EncodingError`.
Binary literals/regexps can match arbitrary bytes, including NUL and invalid UTF-8.

The helper uses P4 staging/full-buffer recovery internally. Relative, idle and total
budgets retain the core semantics; continuation does not reset them. A sink's `write`
is synchronous: deadlines are checked after it returns and do not forcibly interrupt
a blocking write. Slow sinks need their own timeout/backpressure policy.

## Sink failure and output ceilings

The reusable writer handles partial writes and rejects zero, negative, non-integer
or over-reported write counts. It updates accepted and sink-byte counts only for
confirmed progress.

`CaptureSinkError < CaptureError` exposes:

- `bytes_written`: bytes confirmed during the failing append.
- `progress`: frozen totals for `captured_bytes`, `sink_bytes`, `retained_bytes`.
- `buffer`: frozen retained output at failure.
- `rejected`: the unconfirmed remainder of that append.
- `cause`: the original sink exception or invalid-progress error.

The session helper consumes only confirmed prefix bytes on failure, leaving the
remaining matching bytes, terminator and staged data inspectable. The caller can
choose a new operation/sink explicitly; no automatic retry risks duplicating output.
A sink that writes bytes and then raises without reporting a count leaves physical
side effects unknown; confirmed counters cannot infer those hidden writes.

`CaptureLimitError < CaptureError` rejects an append that would exceed `limit:` before
writing any of it. Earlier accepted fragments remain counted. It does not partially
fill the remaining budget, so accepted bytes at failure may be below the ceiling.
The failed fragment remains in the session buffer when using the helper. Both limit
and sink failures make a reusable Capture object fail closed; further appends raise
`CaptureError` instead of silently retrying.

## Reusable capture for application framing

```ruby
capture = Expect4r::Capture.new(sink: output, retain: 1024, limit: 10_000_000)
capture.append(first_fragment)
capture.append(next_fragment)
p capture.progress
p capture.output
```

This primitive does not consume a Session or choose framing. Applications can supply
complete frames, lines or byte fragments using their own protocol rules.

`expect4r-routers` now uses this writer for storage, limits and partial sink accounting.
Echo removal, paging, error recognition, Junos hierarchy tracking and prompt rules
remain in the router application. Existing command output and output-limit exceptions
are retained. Router sink failures now propagate structured `Expect4r::CaptureSinkError`
with the original cause and mark the router uncertain. Router line framing still
requires individual lines to fit its matching buffer; migrating the vendor policies
to bounded no-newline scanning is separate work, not implied by the generic helper.

## Validation

Native macOS ARM64 with rv Ruby 4.0.9: 114 core tests/616 assertions, 28 router
tests/259 assertions, and 20 legacy tests/68 assertions passed. Tests cover binary
output, literal fragmentation against a whole-input reference, UTF-8 boundaries,
explicit regex windows, independent retention/total limits, partial/invalid sink
writes, sink failure at full-buffer/match/EOF transfer, partial timeout output,
following dialogues, total deadlines and router uncertainty. A real PTY produced
300 KB without newlines using a 4 KB matching buffer and 32-byte retained tail.
Both gems built and passed isolated installation checks, including the installed
streaming API; packaged file lists and bytes match current source. The package task
now builds directly from source to prevent stale staging artifacts. See [review validation](REVIEW.md) for subsequent Linux results; [P6 offline replay](REPLAY.md) is now available.
