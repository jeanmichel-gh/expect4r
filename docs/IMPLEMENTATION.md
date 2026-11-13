# V2 implementation and validation

This checkout implements the Ruby 4 dialogue API and an initial router layer.
It is a development implementation for review, not a published release or a
claim of full Tcl/Expect compatibility. Work was done in the Mac checkout;
Linux tests use a disposable copy only.

## Structure

| File | Responsibility |
|---|---|
| `lib/expect4r.rb` | Factories, validation and scoped cleanup |
| `lib/expect4r/session.rb` | Transport ownership, bounded receive buffers and exact writes |
| `lib/expect4r/wait.rb` | Matching, precedence, consumption, time budgets and continuation |
| `lib/expect4r/patterns.rb` | Pattern declarations and reusable rules |
| `lib/expect4r/result.rb` | Immutable received-byte snapshots and event results |
| `lib/expect4r/interaction.rb` | Human terminal handoff and restoration |
| `lib/expect4r/diagnostics.rb` | Streaming literal redaction |
| `applications/routers/lib/expect4r_routers/router.rb` | Login, prompt policy, paging, command capture, modes and configuration |
| `applications/routers/test/fixtures/router_cli.rb` | Independent CLI simulator; does not import production code |
| `legacy/lib/expect4r/legacy.rb` | Preserved loader for the original implementation |

`expect-pty` 0.10.1 owns PTY creation, direct argv startup and child lifecycle.
The wrapper uses its public APIs only. Its matcher and tail-trimming buffers are
not used: expect4r owns matching input and raises on overflow. This avoids a
private backend dependency while preserving the specified ordering, timer and
callback semantics.

## What is exercised

Core tests cover literal/regex/multiline matching, names and captures, suffix
preservation, rule limits, non-consuming waits, empty-match errors, registration
validation, relative/idle/total timers, continuation, fragmented/invalid UTF-8,
EOF with partial output, direct argv execution, explicit shell mode, env/chdir,
failed startup, partial writes/backpressure, owned and borrowed handles, process
cleanup, exceptions/nonlocal returns, concurrent ownership, transcript failures,
secret redaction, multi-session waits and human handoff.

Router tests use real PTYs to talk to the independent simulator. They cover
fragmented login/prompt output, exact whitespace, paging, large-output sinks,
command/device errors, timeout and recovery, partial-output disconnects,
authentication/host-key failure messages, IOS immediate configuration, Junos
candidate commit/discard/lock failure, and IOS-XR candidate commit/abort.

Two runnable examples provide end-to-end checks:

```sh
rv run bundle exec ruby examples/local_dialogue.rb
rv run bundle exec ruby applications/routers/examples/local_router.rb
```

The simulator's output and behavior are synthetic; they are not recordings of
actual IOS/Junos releases. Real transcript regression fixtures can be added after
sanitized device captures are available.

## Verified environments

Verified on 2026-11-13 on native macOS ARM64 using `rv` Ruby 4.0.9:

| Suite | Tests | Assertions | Result |
|---|---:|---:|---|
| Core | 45 | 161 | Passed |
| Router application | 27 | 254 | Passed |
| Historical compatibility | 20 | 68 | Passed |

Earlier, before the mode/ping expansion and package split, Linux ARM64 Ruby 4.0.6
passed 56 modern tests/209 assertions and 20 legacy tests/68 assertions. That
result does not validate the latest changes on Linux.

Core and legacy tests run in different Ruby processes so the old IO patches
cannot affect new engine results. The process cleanup test includes a child
ignoring both HUP and TERM; it verifies KILL fallback and reaping. Time budgets
include pattern-registration time as well as action/receive time.

The macOS terminal-restoration test calibrates one plain-Ruby raw/canonical mode
round trip before taking its baseline. The kernel sets the transient PENDIN bit
on that first transition even without expect4r. The test then compares all
`stty -g` settings exactly across the interaction's exception path; it does not
mask changes to echo/canonical/signal handling.

## Explicit boundaries

- IOS, IOS-XR and Junos policies are simulator-tested. No real router/firmware or
  SSH authentication/host-key infrastructure has been validated. The fixture
  checks handling of those messages, not OpenSSH's correctness.
- Privilege escalation (`enable`), arbitrary vendor banners, proxy-session
  sharing, custom prompt grammars and new/old firmware behavior need further
  adapter fixtures. Supply an exact prompt override for customized boundaries.
- Command echo removal assumes the adapter's terminal echoes its command line.
  Individual output lines must fit the core buffer limit. Capture sinks avoid a
  full duplicate response but do not make arbitrary unbounded regex matching
  possible with constant memory.
- Timeout budgets are cooperative around synchronous callbacks and regexes;
  application code can overrun them. No background reader or asynchronous
  callback cancellation is introduced.
- The wrapper owns the direct child only. Closing SSH does not promise to kill
  a remote job or all descendants. Exceptional cleanup retains the backend's
  ownership/reaping mechanism and reports failure rather than abandoning it.
- Underlying IO/Logger/sink exceptions propagate. Partial command output is
  exposed in normal timeout/EOF CommandResults; arbitrary failing external
  writers do not yet receive a uniform CommandResult wrapper.
- The tests use controlled real delays with tolerance. Dedicated load/stress
  testing and injected-clock coverage can be added before release.
- Background expect dispatch, Tcl glob patterns, Windows PTYs, automatic resize
  handling and the other features explicitly deferred in the functional spec
  are not implemented.

The GitHub Actions workflow defines Linux/minimum-Ruby and macOS/rv-Ruby checks.
It has not run on GitHub; no branch has been pushed and no gem published.

## Package boundary

The root gem contains only generic engine code. `applications/routers` builds
`expect4r-routers`, which depends on `expect4r`; dependency direction is one way.
The router application owns command results/errors, vendor dialogues, context
tracking, ping parsing, fixtures and examples. The historical IO patches live in
`legacy/`; HighLine is a development dependency for that suite only.

Both runnable examples passed. Both gems built successfully. The package check
installed the core and its backend dependencies into an empty gem home, verified
that router/legacy code and HighLine were unavailable, and exercised a real PTY.
It then installed the companion and exercised simulator show/ping through its
installed load path. Run `bundle exec ruby script/check_packages.rb` after building.

Run `rake core`, `rake routers` or `rake legacy` independently. `rake test` runs
all three in separate processes. `rake package_routers` builds both gems.

## Planned debugging and buffering work

See [the design and phased plan](DEBUGGING_AND_BUFFERING.md) for the current
capability inventory, Tcl/Expect comparison, proposed APIs and acceptance tests.
P1 events, P2 scoped formatting, and P3 recording/history are implemented and
tested; P4–P6 remain planned. Current validation: 77 core tests/382 assertions, 27 router
tests/254 assertions, 20 legacy tests/68 assertions, plus gem builds and isolated
installation checks on rv Ruby 4.0.9.
