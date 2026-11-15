# Recovering from a full matching buffer

Implemented in P4, 2026-11-13. Default overflow behavior remains unchanged.
Applications opt into incremental matching by registering a `full_buffer` action.
This feature is generic core functionality; no vendor policy is involved.

## Consume a deliberate prefix

```ruby
require 'expect4r'
require 'rbconfig'

Expect4r.spawn(RbConfig.ruby, '-e', 'STDOUT.write("x" * 200_000 + "DONE>")',
               buffer_limit: 4096) do |session|
  output = ''.b
  result = session.expect!(timeout: 10, total_timeout: 30) do
    on 'DONE>', name: :complete
    full_buffer do |event|
      # Retain four bytes so the five-byte terminator can straddle reads/windows.
      output << consume_buffer(event.before.bytesize - 4)
      exp_continue(reset_timeout: false)
    end
  end
  output << result.before
  puts output.bytesize # 200000
end
```

The example retains all output in an application String, so total output storage
is not bounded. It demonstrates bounded matching memory. Generic streaming capture
with sink failure handling belongs to P5. When writing to a sink yourself, confirm
that a prefix was written before consuming it; partial writes must be handled.

`consume_buffer(count)` removes a positive byte count from the start of the matching
buffer and returns a frozen String. It is safe in an action. Counts larger than
retained matching bytes are rejected. No automatic prefix is chosen or discarded.

A finite retained suffix is sufficient for the literal terminator above. Arbitrary
Ruby regexps may need unbounded history; this feature does not promise to recognize
an unbounded pattern after an application discards bytes it needs.

## Grow instead of consuming

Supply an explicit ceiling to constrain growth:

```ruby
Expect4r.spawn(program, buffer_limit: 4096, buffer_ceiling: 16_384) do |session|
  session.expect! do
    on long_pattern
    full_buffer do
      resize_buffer(buffer_limit * 2)
      exp_continue(reset_timeout: false)
    end
  end
end
```

`resize_buffer(limit)` accepts a positive Integer or explicit `nil` for unlimited
capacity. It rejects a finite size below retained matching bytes and any value
beyond a configured ceiling. A finite ceiling requires a finite initial limit that
fits within it and prohibits resizing to `nil`. With no ceiling, growth is constrained
only by explicit application choices; memory is not automatically expanded. At the
ceiling, the example raises instead of silently discarding output.

## Handler and result semantics

- `full_buffer(from: session)` targets one source of an aggregate wait. Omit `from:`
  for a handler applying to all sources. A source-specific handler takes precedence.
- A block is required; duplicate handlers are rejected. Combining a handler with
  `consume: false` is rejected before reading. Nested waits inside actions still
  raise `ReentrancyError`.
- The action runs with its source Session as `self`. Its immutable Result has
  `status: :full_buffer`, `full_buffer? == true`, and a `before` snapshot of the
  matching buffer. It does not automatically consume bytes.
- An action that returns normally returns that Result to the script. Use
  `exp_continue` to keep waiting. After either normal return or continuation, the
  action must have consumed bytes or increased capacity; otherwise
  `BufferProgressError` is raised. Exceptions and nonlocal exits abort the action.
- Text patterns are tried in declared order before reporting full capacity. A match
  completed exactly at the capacity boundary wins. Pending staged bytes are not yet
  part of matching input, so pattern priority applies to visible matching buffers.
- An already-observed EOF precedes a full-buffer action. An expired deadline precedes
  a full-buffer action, subject to the initial zero-relative-time poll semantics. After continuation, an expired total deadline precedes further
  matching. Existing text-match/timeout precedence otherwise remains unchanged.
  EOF cannot be observed until pending staged input is drained and the reader is
  polled again; a final capacity-sized buffer can therefore invoke the handler first.
- `exp_continue` retains its existing relative/idle reset policy. `reset_timeout: false`
  retains those deadlines; total time never resets. Moving staged bytes does not reset
  idle time. Only fresh IO does. Actions are synchronous; deadlines are checked when
  the action returns or continues, not by forcibly interrupting Ruby callback code.

## Matching and staging are separate

For a source with a handler, a physical read is staged, then only available matching
capacity is exposed to the matcher. The rest of the already-read chunk is retained.
Before another physical read, staged data must be drained. Staging is limited to one
read chunk (at most 65,536 bytes per source), independently of matching capacity.
This is a staging bound, not a bound on every allocation: result snapshots, redaction,
recordings, capture output and kernel buffers have separate memory costs.

Public inspection:

| API | Meaning |
|---|---|
| `session.buffer` | Frozen snapshot of visible matching bytes |
| `session.staged_buffer` | Frozen snapshot of already-read bytes not yet exposed |
| `session.staged_bytes` | Current staging byte count |
| `result.staged` | Frozen mapping from Sessions to frozen staged snapshots at result creation |
| `session.buffer_offset` | Absolute byte offset of the visible buffer's start |
| `session.clear_buffer` | Returns and clears matching plus staged bytes, and resets failed-buffer state |

`Result#before`, `match` and `after` still describe the visible matching window.
Timeout and full-buffer results carry staged snapshots too. Handler exceptions or
sink failures retain unconsumed matching and staged bytes; bytes already consumed by
application code are not rolled back. Session ownership and recovery settings restore
on errors and nonlocal exits. A new wait can register a handler to resume recovery.

If a subsequent wait has no handler and staged input cannot fit, it raises
`BufferOverflow` with matching bytes in `buffer` and the staged remainder in
`rejected`; those staged bytes remain inspectable. Clear the failed buffer before
matching again, as with ordinary overflow. For a source that never opted into
recovery, the original overflow contract is unchanged: the retained prefix and
rejected remainder are exposed in the exception, without automatically staging the
rejected bytes. Clearing that legacy failure returns only its retained buffer.

`interact` drains staged output as it forwards bytes and preserves any remaining
staged data on escape/timeout/error. It restores its previous recovery and terminal
settings before returning. Recording/transcript delivery happens once per physical
read, not again when staged data is exposed. Metadata adds `full_buffer`,
`buffer_resize` and `stage_drain` events.

## Validation

Native macOS ARM64, rv Ruby 4.0.9: 97 core tests/468 assertions, 27 router tests/254
assertions, and 20 legacy tests/68 assertions passed. Coverage includes capacity-boundary
matches, a larger-than-capacity read, prefix consumption and growth, ceiling validation,
no-progress actions, callback failures and nonlocal exits, retained staged snapshots,
UTF-8 boundaries, aggregate-source priority, EOF and deadline behavior, unchanged
overflow defaults, exact transcript/recording bytes, and manual handoff. A real PTY
produced 200 KB while using a 4 KB matching buffer. See [review validation](REVIEW.md) for subsequent Linux results.
