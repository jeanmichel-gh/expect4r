# expect4r

Script interactive terminal programs in Ruby, with an Expect-style pattern/action DSL.
Ruby **4.0.6+**, Linux and macOS. This is the v2 development implementation; real IOS,
IOS-XR and Junos devices have not yet been validated.

```ruby
require 'expect4r'

Expect4r.spawn('ssh', '-o', 'StrictHostKeyChecking=yes', '-l', user, host) do |session|
  session.expect!(timeout: 10, total_timeout: 30) do
    on /[Pp]assword:\s*\z/ do
      send_line password, sensitive: true
      exp_continue
    end
    on /router#\z/, name: :ready
  end

  session.send_line 'show version'
  puts session.expect!(/router#\z/, timeout: 15).before
end
```

Strings match literal substrings; regular expressions use Ruby semantics. Patterns
are tried in declaration order. `before`, `match`, `after` and `captures` are immutable
byte snapshots. Completed lines are never removed implicitly, and a matched suffix
is retained for the next wait.

`expect` returns `:matched`, `:timeout` or `:eof` results. `expect!` raises on unhandled
timeout/EOF; explicitly requesting or handling an event acknowledges it.
`exp_continue` resumes matching and resets the relative timeout; use
`exp_continue(reset_timeout: false)` to retain it. `total_timeout` never resets.

## Development with rv

```sh
rv run bundle install
rv run bundle exec rake test
rv run bundle exec ruby examples/local_dialogue.rb
rv run bundle exec ruby applications/routers/examples/local_router.rb
rv run bundle exec rake package_routers
```

The `.ruby-version` selects Ruby 4.0.9. To use another supported installed version:

```sh
rv run --ruby 4.0.6 bundle exec rake test
```

No VM, credentials or routers are needed. The tests use real local PTYs, socket
pairs and an independent IOS/Junos/IOS-XR CLI simulator. Legacy tests run in a
separate Ruby process because the legacy library patches IO and Kernel.

## Router application

Router automation is a separate gem, **expect4r-routers**, in
[`applications/routers`](applications/routers/README.md). It owns IOS/IOS-XR/Junos
login, prompts, user/admin/configuration modes, configuration depth, paging,
show and vendor-specific ping. Load it with `require 'expect4r_routers'` and use
`Expect4rRouters.open(...)`. The core installs and runs without this application
or its vendor rules. See its README for examples and current limitations.

## Ownership and limits

- Block factories ensure cleanup on exceptions and nonlocal exits. Sessions own
  spawned children; `open(io, own: false)` borrows existing IO.
- One operation owns a session at a time. Callbacks can write but cannot recursively
  read the same session. Module-level `Expect4r.expect(from: [...])` waits on several.
- Unmatched buffers default to 1 MiB. Overflow raises with retained/rejected bytes;
  it does not silently trim input. Explicitly clear a failed buffer before reuse.
- `interact` temporarily forwards terminal IO and restores input terminal settings.
  Ctrl-T returns to the script. IO/terminal errors propagate after restoration.
- `sensitive: true` registers literal secrets for diagnostic/transcript filtering.
  Results, protocol IO and explicit terminal output remain raw.

## Diagnostic events

Pass `diagnostics: ->(event) { ... }` and an optional `label:` to a session factory
to observe matching, byte ranges, consumption, deadlines and manual handoffs.
Callbacks receive frozen metadata Hashes without protocol bytes or pattern text.
Tracing is disabled by default. Use `session.with_debug(output: $stderr) { ... }`
for readable scoped diagnostics; add `bytes: true` for bounded, filtered previews
or `format: :hex` for hex output. See the [design and usage](docs/DEBUGGING_AND_BUFFERING.md)
for event semantics, sink failures and the remaining implementation phases.

Use `recording: file` for versioned RX/TX JSONL recordings, and
`history: { max_events: 100, max_bytes: 65_536 }` for bounded metadata history.
See [recording and history](docs/RECORDING_FORMAT.md) for usage, secret masking,
completion and failure semantics. Replay remains planned.

Opt into buffer recovery with a `full_buffer` action. It can explicitly consume
prefixes or grow capacity under a configured ceiling while preserving unread data.
See [buffer recovery](docs/BUFFER_RECOVERY.md) for examples, staging and deadlines.
Without a handler, overflow still raises.

## Existing scripts

V2 is a major API change. The historical implementation lives under `legacy/`
and is excluded from both new gems. To run an existing script from this checkout:

```sh
ruby -Ilegacy/lib your_script.rb
```

Use `require 'expect4r/legacy'` in that script and install HighLine separately.
Legacy and modern APIs must run in separate processes. See the
[legacy examples](legacy/README.rdoc) and [migration notes](docs/MIGRATION.md).

## Design and validation

- [Functional specification](docs/FUNCTIONAL_SPEC.md)
- [Debugging and buffering design and implementation plan](docs/DEBUGGING_AND_BUFFERING.md)
- [Implementation scope and validation](docs/IMPLEMENTATION.md)
- [Original repository assessment](ASSESSMENT.md)

`expect-pty` 0.10.1 supplies public PTY creation and process lifecycle APIs. The
expect4r matcher implements the stricter buffering, continuation, deadline and
callback contracts. The dependency is pinned until compatibility checks justify
an upgrade. The v2 implementation is locally tested software, not a promise of
complete Tcl/Expect compatibility or validated support for every vendor release.
