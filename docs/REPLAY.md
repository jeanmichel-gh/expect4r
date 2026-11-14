# Offline dialogue replay

Implemented in P6, 2026-11-13. Replay reads version 1 structured recordings and runs
normal expect4r code against a local selectable transport. It starts no child, makes
no SSH/network connection and executes no content from the recording.

## Replay a recorded script

```ruby
require 'expect4r'

Expect4r.replay('dialogue.jsonl', fragment_size: 1) do |session|
  session.expect!('ready>')
  session.send_line('go')
  result = session.capture_until!('DONE>', retain: 1024)
  puts result.output_bytes
end
```

The source is a file path, a readable IO at its current position, or a previously
loaded `ReplayTrace`. A caller-provided IO is borrowed and not closed. This accepts
[structured recordings](RECORDING_FORMAT.md), not legacy text transcripts.

The factory returns the block's value, or an owned Session without a block. Close
non-block sessions explicitly. Normal session settings (limits, logger, diagnostics,
history, recording and line ending) are supported. The replay Session has no child
PID; child-specific `wait`/`terminate` operations are unsupported.

`fragment_size: nil` preserves recorded read-observation boundaries, subject to the
session's maximum read size. A positive Integer caps each delivered fragment; use 1
to stress byte-boundary assumptions. Consecutive recorded write observations can
be verified by one script write, and one observation can be split across writes.
TX contents are checked as a byte stream, not a sequence of identical write calls.

Ready input is queued independently of how much the script reads. For example, a
regexp may match `Password:` before the last space of `Password: ` has been read.
The script may respond immediately, and the queued space is still delivered in
order. Alternate fragmentation can expose greedy/optional-pattern assumptions;
replay does not promise every pattern has identical match boundaries under every
fragmentation. The router application now handles split pager control spaces without
removing genuine output indentation.

## Timing and EOF

| Option | Behavior |
|---|---|
| `timing: :immediate` | Default: remove recorded delays; RX becomes available when preceding TX observations have been verified |
| `timing: :scaled` | Schedule RX, EOF and read-error observations from recorded elapsed times using the monotonic clock |
| `speed: 1` | Positive finite scale factor for scaled timing; 10 runs at ten times the recorded speed |

Scaled timing uses one condition-variable-driven timer thread per replay. Closing
the Session signals and joins it, then closes both pipe endpoints. Immediate replay
needs no worker thread. Actual Ruby wait deadlines still govern `expect`, capture
and `interact`; there is no virtual clock in this implementation.

The timestamps describe observed transport IO, not independent measurements of
remote emission or network latency. TX matching checks content; it does not make
the caller sleep until the original write timestamp. In scaled mode, a write before
its preceding scheduled input has become available is a replay mismatch.

EOF is delivered only if explicitly observed in the recording. Finishing a recording
does not manufacture transport EOF: a trace that ended after a timeout remains
silent after its last observed input, so a new wait needs its own timeout. Historical
wait timeout metadata is not blindly injected; use scaled timing and appropriate
script budgets to reproduce silence between later input observations.

## Redacted recordings

Inspect required substitutions without printing protocol contents:

```sh
rv run bundle exec ruby -Ilib script/replay_info.rb dialogue.jsonl
```

Or inspect spans programmatically:

```ruby
trace = Expect4r::ReplayTrace.load('dialogue.jsonl')
p trace.redactions
# [{ direction: :tx, stream_offset: 0, bytes: 7 }, ...]

Expect4r.replay(trace, substitutions: { [:tx, 0] => "secret\r" }) do |session|
  # Supply the corresponding value in the script too.
  session.send_line('secret', sensitive: true)
end
```

The example substitution map is illustrative: provide exactly one entry for **each**
RX and TX redaction span reported by your trace. Keys are `[direction_symbol,
absolute_stream_offset]`; values must be Strings with exactly the recorded span's
byte length. Unknown keys, missing values and changed lengths are rejected before
opening the replay transport. Individual spans may be fragments of a logical secret.
Masks are not wildcards, and replay never silently accepts arbitrary secret bytes.

Substitution values are automatically registered with session diagnostic redaction.
They remain raw protocol bytes and may appear in explicit results/manual output,
just like ordinary `sensitive:` values. Mismatch messages show offsets, not expected
or actual payload bytes. No arbitrary Ruby classes are instantiated from metadata.

## Verification and errors

Verification runs automatically when the Session closes, including scope cleanup.
`session.verify_replay!` performs the same check explicitly.

By default, every recorded TX byte and recorded transport failure must be exercised.
Ready/trailing RX and an unread EOF may remain, because a script can legitimately
stop after matching a prompt before draining the original read observation. Set
`require_all_reads: true` on the factory to also require every recorded RX byte and
EOF to be delivered. A one-off `verify_replay!(require_all_reads: true)` can tighten
an individual check; it does not change the factory's close-time policy.

| Error | Meaning |
|---|---|
| `ReplayFormatError` | Invalid/incomplete file, unsupported version, inconsistent ranges/counts, malformed payload/mask, or invalid substitutions |
| `ReplayMismatchError` | Different or unexpected outgoing bytes; `progress[:stream_offset]` gives the first absolute TX offset |
| `ReplayIncompleteError` | Required TX/input/failure observations remain unexercised |
| `TransportError` | Recorded read/write failure, using `ReplayTransportFailure` as its cause; `cause.recorded_class` identifies the recorded class |
| `WriteTimeout` | Recorded write-timeout observation, with confirmed bytes for the caller's current write |

All replay validation/verification errors inherit `ReplayError`. Recorded transport
errors are deliberately normalized rather than constructing arbitrary recorded
exception classes or claiming a live operating-system errno. Recorded partial TX
progress is returned before a following failure. This preserves core write accounting.
A mismatch fails the replay closed; retrying on that Session does not erase it.

A malformed or incomplete recording is rejected before opening the replay transport.
The reader checks header/version, contiguous sequence and per-direction byte ranges,
monotonic elapsed times, strict base64, payload lengths, masked spans, explicit EOF
ordering and a successful final completion record with matching totals. There is no
partial-file mode. IO observations and delayed payload segments are associated by
byte range, not by adjacency.

On scope errors, cleanup still releases descriptors and stops the timer. A failed
close-time verification is recorded in `cleanup_errors` and does not replace an
existing application error. Verification checks transport usage, not whether the
script made every intended business assertion; normal Ruby tests still express those.

## Fixture tools and validation

```sh
rv run bundle exec ruby examples/local_replay.rb
```

This records a real local PTY dialogue, then replays it one byte at a time and
compares output. CI runs it too. The parser currently loads the complete recording
and reconstructed streams into memory; replay is a fixture/test tool, not a bounded
streaming reader for arbitrarily large recordings.

Native macOS ARM64, rv Ruby 4.0.9: 130 core tests/700 assertions, 30 router tests/266
assertions and 20 legacy tests/68 assertions passed. Tests cover recording round trips,
one-byte reads, split/coalesced writes, queued RX tails, explicit redaction substitutions,
malformed files, mismatch offsets, completeness, partial writes/errors, scaled silence,
timer cleanup, aggregate waits and manual interaction. IOS, IOS-XR and Junos simulator
recordings replay paging, configuration depth and polymorphic ping with identical
application results. Real-device validation and current-phase Linux validation remain
outstanding.
