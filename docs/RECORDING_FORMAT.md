# Dialogue recording and diagnostic history

Implemented in P3, 2026-11-13. Version 1 is a development format; [P6 replay](REPLAY.md) is implemented. The incoming-only `transcript:` API remains available separately.

## Usage

```ruby
require 'expect4r'

File.open('dialogue.jsonl', 'wb') do |file|
  Expect4r.spawn('ssh', 'lab-router', recording: file,
                history: { max_events: 100, max_bytes: 65_536 }) do |session|
    session.redact(ENV.fetch('ROUTER_PASSWORD'))
    session.expect!(timeout: 10) do
      on /[Pp]assword: ?\z/ do
        send_line ENV.fetch('ROUTER_PASSWORD'), sensitive: true
        exp_continue
      end
      on /router#\z/, name: :ready
    end
    session.send_line('show version')
    result = session.expect(/router#\z/, timeout: 10)
    if result.timeout?
      warn session.diagnostic_history.inspect
      warn "Evicted events: #{session.diagnostic_history_dropped}"
    end
  end
end
```

Recording is opt-in, synchronous and bidirectional. The caller owns the writable
sink; session cleanup completes the recording before the outer file block closes.
Use a file per session. Sharing a sink between sessions is not a supported multiplexed
format. Neither process arguments nor environment variables are automatically saved.
Registration must precede secret receipt; redaction cannot rewrite earlier records.
Explicit results and manual terminal output remain raw.

History is independently opt-in. Both `max_events` and `max_bytes` must be positive
integers. It stores metadata only, never protocol payloads, patterns or captured
values. `diagnostic_history` returns a frozen snapshot of frozen events.
`diagnostic_history_bytes` counts retained events' JSON-encoded byte sizes (not total
Ruby heap usage); `diagnostic_history_dropped` counts evictions. An event larger than
the byte budget is evicted too. This history is independent of matching capacity and
recording payload storage. Inspect the result's session to retrieve failure history.
Caller-provided rule names and labels should be suitable for export.

## JSON Lines format

Every line is one JSON object. A single header precedes records with monotonically
increasing `sequence` values and `elapsed` seconds from the header's monotonic origin.
Payload masking does not change raw-stream byte offsets.

| Type | Content |
|---|---|
| `header` | `format: "expect4r-dialogue"`, `version: 1`, session ID, label, UTC wall-clock origin, monotonic origin, Ruby/platform/expect4r versions, transport (`pty` or `io`) |
| `io` | Observation time, direction `rx`/`tx`, raw `stream_offset` and byte count |
| `payload` | Direction, starting raw offset, byte count, `encoding: "base64"`, `data`, and `redactions` |
| `event` | P1 metadata under `metadata`: waits, rule decisions, consumption, interaction, deadlines, EOF and errors |
| `end` | `complete` boolean and total observed byte counts per direction |

TX observations describe confirmed partial writes, not the originally requested
write length. Request size and transport errors appear in metadata events. RX
observations cover all bytes read, including bytes rejected by a matching-buffer
overflow. EOF is a metadata event, not an empty payload. Each direction has its own
zero-based offsets; ranges use byte counts.

IO observation timestamps and chunk boundaries are retained immediately. Payload
segments may be emitted later because an incomplete trailing secret prefix is held
until more data arrives. Associate segments with observations by direction and byte
range, not by adjacency or equal chunk sizes. Metadata can appear between an IO
observation and its payload. A payload's elapsed time is its emission time; original
arrival/write times remain on the corresponding IO observations.

## Redaction

Payload data is lossless base64 for ordinary bytes. Registered secret occurrences
are replaced with NUL bytes of the same length; `redactions` lists absolute
`stream_offset` and `bytes` for those ranges. This explicitly distinguishes masks
from genuine NULs. Redaction spans can cross observation boundaries. Overlapping
secret matches are merged, and trailing incomplete secret prefixes are conservatively
masked during finalization. Each direction maintains its own redaction state.

For example, observing `pass` then `word>` with registered secret `password`
produces nine payload bytes: eight masked NULs followed by `>`, with an eight-byte
redaction span starting at offset zero. The two original IO observations remain.
Buffered undecided payload tails are bounded by the longest registered secret;
ordinary content and overlap-safe masked prefixes are emitted incrementally.

A filtered recording is not an exact wire capture. Strict replay requires
explicit substitutions for marked spans; zero masks are not wildcards.
Literal filtering is not a detector for arbitrary credentials or other private data.
P2 buffer snapshots remain suppressed after secrets are registered. Existing outgoing
Logger byte tracing now also maintains redaction state across separate write calls.

## Failure and completion

A recording sink failure propagates during an ordinary operation, marks
`session.recording_failed?`, and permanently disables further recording for that
session. Received protocol bytes remain buffered. A partial failed sink write may
leave a truncated JSON line. Cleanup still releases/reaps the transport. Secondary
recording errors during cleanup do not replace an existing application error.

A failed recorder never writes a successful `end` record. A transport cleanup failure
produces `complete: false` if the recording sink still works. Missing, false or
truncated completion must be treated as incomplete by strict readers.

`complete: true` means the recorder finished all observations made by this session;
it does not mean the remote command succeeded or that unread kernel/child output was
captured. A fully recorded timeout, partial write or buffer overflow can still have a
complete recording. Buffered-file flush/fsync/durability is the caller's responsibility;
the recording writer provides no automatic rotation or retention service. Offline
replay is provided by P6.

## Validation

Native macOS ARM64 with rv Ruby 4.0.9: 77 core tests/382 assertions, 27 router
tests/254 assertions, and 20 legacy tests/68 assertions passed. Both gems built and
passed isolated installation checks. Tests cover binary bytes, fragmented and
overlapping secrets, redaction against an independent whole-stream reference,
partial transport and sink writes, overflow bytes, bounded history, sink failures
and primary-error preservation. See [review validation](REVIEW.md) for subsequent Linux results.
