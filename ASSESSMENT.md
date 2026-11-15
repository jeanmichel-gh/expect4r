# expect4r: initial assessment

Reviewed 2026-11-12, starting at commit `a8d681a7d1c2b2d98c90f716f66c5a40e7fd6c9d`.

## Verdict

expect4r has useful networking knowledge and convenient router operations, but its engine is a weak foundation for a general-purpose Expect implementation. Its architecture explains the syntax dissatisfaction: dialogue rules are embedded in library internals instead of forming the central user-facing abstraction. Cosmetic DSL changes alone would conceal the underlying problems.

My recommendation is to preserve the router-facing concepts and examples, establish a behavior specification, and evaluate an existing general-purpose engine before building a replacement. If a new engine is warranted, implement it separately and put a compatibility layer over it. Do not attempt an all-at-once rewrite of every router adapter.

## What the repository actually implements

The source comprises roughly 2,400 lines of Ruby. `lib/expect/io.rb` contains the IO extensions, PTY lifecycle, matching, login, command execution, terminal interaction, exceptions and global debugging. `lib/misc/base.rb` adds credentials, SSH/telnet command construction and a global session registry. Vendor modules implement prompt recognition, mode transitions, paging, ping dialogues, output checks and commits.

There are three related matching loops: `expect`, `_login`, and `_putline_`. Their precedence and response semantics differ. Callback invocation varies between no arguments, the session argument, and a callback return value sent to the child. There is no single dialogue model on which the other operations are built.

The README presents router automation as the primary API. That is consistent with the implementation, even though the name suggests a broader Expect replacement.

## What is worth retaining

- PTYs are the appropriate primitive for programs that expect a real terminal. A Ruby implementation can use the shipped PTY extension without requiring Tcl.
- `exec`, `config`, mode awareness and paging express useful networking tasks.
- The IOS, IOS-XR, Junos and Vyatta adapters capture operational knowledge that should become fixtures and scenario tests.
- Proxy login and returning control to a human are valuable capabilities.
- Existing scripts and examples give a practical migration target.

These are good product ingredients. They need a more reliable dialogue engine and clearer ownership of session state.

## Findings supported by execution

The following outcomes reproduced on Ruby 3.2.11, 3.3.13 and 3.4.12. Reproduce with `bundle exec ruby -Ilib script/diagnose_expect.rb`.

| Behavior | Observed result | Explanation |
|---|---|---|
| Match `/first\r\nsecond>/` | Timeout | Completed CRLF lines are removed from the active matching buffer before the whole pattern can match. |
| Match literal `ready>` in `prefix ready>` | Timeout | String patterns use whole-buffer equality through `case`, unlike normal Expect literal substring matching. |
| Timeout 0.1 s while 12 bytes arrive at 0.03 s intervals | Returns around 0.46–0.47 s | Every `IO.select` receives the full timeout. This is an idle timeout, not an overall operation deadline. |
| Response callback matching `confirm\r\n` | Callback never runs | Built-in EOL handling takes precedence and consumes the completed line. |
| Pipe reaches EOF after unmatched partial output | External watchdog interrupts it | `getc` returning nil does not record EOF in the nonempty buffer. The loop keeps polling an EOF-ready descriptor. |

The pipe test isolates a reader defect; it does not establish that every PTY exit hangs. Linux PTYs may instead raise EIO. That exception takes a different path, which also needs explicit coverage.

A PTY response test using `Expect4r::Base` exposed another coupling: sending calls `connect_retry`, which exists on `BaseLoginObject` but not `Base`. `Shell` inherits `Base`, so its inherited send path has the same unresolved dependency. The passing PTY dialogue tests use the existing `BaseLoginObject` abstraction.

## Additional findings from code inspection

These findings are structural or inferred from source; they were not all reproduced against real devices.

1. **Process lifecycle and concurrency.** `spawn` starts a thread that waits on the child while the caller polls shared instance variables. Startup exceptions happen in that thread, while `Thread.abort_on_exception = true` changes behavior for the entire embedding application. Cleanup sends KILL and kills the waiter thread; child exit status is not exposed as a stable API. A session should own descriptors, PID and wait status explicitly.
2. **Global effects.** Loading the library patches IO and Kernel. Sessions accumulate in a global registry until process exit. Constructing `Shell` changes the parent environment's prompt variables and spawns immediately. These choices complicate embedding, testing and parallel sessions.
3. **Matching efficiency.** Input is read a character at a time. The current buffer is repeatedly joined and scanned, including eager construction of disabled debug messages. Long lines can incur quadratic work. Buffer size and encoding policies are undefined.
4. **Command boundaries.** `spawnee` interpolates host, user and options into one string passed to PTY. Shell interpretation can occur when metacharacters are present. Use an executable and separate argv values, with an explicit shell mode when needed.
5. **Command mutation.** `exp_send` strips lines, and `_putline_` collapses whitespace by default. That can change quoted shell arguments or significant configuration text. Its return shape also depends on string length rather than the number of commands (`lines.size == 1`).
6. **Prompt heuristics.** Broad prompts ending in `>`, `#` or `$`, plus a 0.2-second quietness check, can confuse ordinary output with readiness. Prompt recognition belongs in explicit adapter policy.
7. **Recovery semantics.** Reconnection can replay operations after partial execution without knowing whether the remote command already took effect. Recovery and command replay should be separate decisions, especially for configuration.
8. **Credentials.** The default password encryption is reversible using a fixed built-in key derivation and does not set a random IV. It provides obfuscation, not a meaningful secret-storage boundary. Debugging can also expose sent text. Authentication and redacted logging need explicit contracts.
9. **Adapter error paths.** Examples include `rollack` in Vyatta's commit-failure path and IOS-XR's `Iox::SemanticError` reference, while the error class is declared under `Router::Error`. Mode restoration generally lacks `ensure`, and commit behavior varies by adapter.
10. **Errors and results.** Many exceptions implement `err_msg` without initializing the standard exception message. Nested response arrays, prompt state and return codes are mixed together. A structured result should distinguish matched text, preceding output, captures, timeout, EOF and process status.

## Tcl/Expect as the design reference

The important abstraction is an ordered collection of pattern/action alternatives, with timeout and EOF as explicit events. Matches consume input while preserving what follows. `exp_continue` resumes matching; its default resets the timer, while `-continue_timer` preserves it. Expect also distinguishes closing IO from waiting for process exit, and supports multiple spawned processes and human interaction.

Reference: [official Expect manual](https://core.tcl-lang.org/expect/doc/trunk/expect.man).

A Ruby API can express the same dialogue structure with blocks. It should document intentional differences in regular expressions, globbing, terminal filtering and event handling rather than claim complete compatibility prematurely.

## Ruby's bundled expect

I inspected and executed the shipped `expect.rb` in all three tested Ruby images. Their SHA-256 hashes are identical:

`46ad443548335032da340ef12b11479f67db7075a15bdd9b6f88aa8353bcc0ef`

The primitive accepts one String or Regexp, returns the consumed buffer and capture groups, and returns nil for timeout or EOF. The probes confirm multiline and literal substring matching work. The trickle-output test still takes about 0.47 seconds with timeout 0.1. It has no pattern/action DSL, continuation control or session lifecycle abstraction.

This establishes no expansion between these tested versions; it is not an audit of every historical Ruby release. Reproduce with `ruby script/compare_stdlib.rb`.

Reference: [Ruby 3.4 IO#expect documentation and implementation](https://docs.ruby-lang.org/en/3.4/IO.html#method-i-expect).

## Community alternatives

Checked published metadata and source on 2026-11-12. Release recency is evidence about publication, not proof of maintenance quality or correctness.

| Candidate | Evidence | Assessment |
|---|---|---|
| `ruby_expect` 1.7.5 | Published 2020-07-09; local multiline/send/reply/cleanup smoke test passed on all three target Rubies. Offers `procedure`, `any`, `each` and pattern blocks. | Relevant DSL reference. Source uses wall-clock deadlines and one-second select intervals. Needs a deeper lifecycle and timeout audit before adoption. |
| `expect-pty` 0.9.6 | Requires Ruby >=3.4; local multiline/send/reply/cleanup smoke test passed on 3.4.12. | Strong candidate for a focused evaluation if 3.4 is acceptable. |
| `expect-pty` 0.10.1 | Published 2026-10-30; published metadata requires Ruby >=4.0.6. Current source offers pattern blocks, continuation, explicit results, PTY/borrowed IO, multi-session waits and terminal handoff. | Closely overlaps the proposed engine. Latest version is outside the requested Ruby range; not runtime-tested here. Its own compatibility document disclaims full Tcl equivalence. |
| `expectr` 2.0.2 | Latest published release 2015-03-16. | Historical alternative; not runtime-tested in this review. |

For `ruby_expect`, the installed 1.7.5 package reports `RubyExpect::VERSION` as 1.7.4. The package metadata identifies the tested version; this small inconsistency is another reason to check implementation details instead of relying on the README.

Sources:

- [ruby_expect repository](https://github.com/abates/ruby_expect), inspected at `662945beb2fb599f47a2490d7ca03489e3e1e841`.
- [ruby_expect published metadata](https://rubygems.org/api/v1/gems/ruby_expect.json).
- [expect-ruby repository](https://github.com/gatework/expect-ruby), inspected at `8303e641d247fffeed693b15fb9dee45a69d262d`.
- [expect-pty 0.9.6 published requirements](https://rubygems.org/api/v2/rubygems/expect-pty/versions/0.9.6.json).
- [expect-pty 0.10.1 published requirements](https://rubygems.org/api/v2/rubygems/expect-pty/versions/0.10.1.json).
- [expectr published metadata](https://rubygems.org/api/v1/gems/expectr.json).

Optional community smoke tests are in `script/compare_community.rb`; those gems are deliberately not dependencies of expect4r.

## Recommended direction

First decide whether Ruby 3.2 and 3.3 are long-term support requirements or just migration checkpoints. If 3.4 is sufficient, evaluate `expect-pty` 0.9.6 against the same behavioral contract and examine the maintenance implications of staying on that release. If all three versions must remain supported, compare a maintained fork/backport with a small new engine. `ruby_expect` is another candidate for that evaluation, not an automatic recommendation.

The architecture should have three layers:

1. **Session and transport:** explicit argv spawn, owned versus borrowed IO, chunked nonblocking reads, bounded buffering, monotonic deadlines, deterministic EOF, close and wait.
2. **Dialogue:** ordered pattern/action blocks, captures and consumed-prefix results, scoped reusable rules, explicit timeout and EOF handlers, continuation with defined timer behavior.
3. **Router adapters:** authentication scenarios, paging, prompt policy, command output, mode transitions and explicit configuration/commit policies.

A proposed interface, not implemented in this change:

```ruby
Expect4r.spawn('ssh', '-l', user, host) do |session|
  session.expect(timeout: 10) do |patterns|
    patterns.on(/login:\s*$/i) do
      session.send_line(user)
      session.exp_continue
    end
    patterns.on(/password:\s*$/i) do
      session.send_line(password, sensitive: true)
      session.exp_continue
    end
    patterns.on(/router[>#]\s*$/)
    patterns.timeout { raise LoginTimeout }
    patterns.eof { raise ConnectionClosed }
  end
end
```

Use a supported existing engine behind this interface if it passes the contract. The user-facing syntax and router layer need not dictate who implements the matcher.

Before selecting an engine, test competing patterns and precedence, unconsumed suffixes, multiline and fragmented UTF-8, total versus idle timeouts, continuation timer reset, EOF with buffered data, immediate child exit, failed exec, process cleanup, paging and interaction restoration. Then port one adapter with a local simulated router and transcript fixtures. Keep actual device checks distinct from simulated behavior.

## Changes made for this baseline

- Added a gemspec and Gemfile with explicit test/build dependencies; the working development baseline declares Ruby >=3.2.
- Replaced obsolete Jeweler/RubyForge packaging tasks with current Rake/RDoc/RubyGems tasks and corrected the test load path.
- Repaired the registry test's order dependence and made its require self-contained.
- Added three real PTY tests: prompt without newline, prompt/response dialogue and silent-child timeout.
- Added diagnostic and comparison scripts, README development instructions and a proposed GitHub Actions matrix.
- Kept all runtime `lib/` files unchanged to separate compatibility setup from semantic repairs.

| Runtime, Linux ARM64 containers on the SSH VM | Suite | Fresh gem build |
|---|---|---|
| Ruby 3.2.11 | 20 tests, 68 assertions, 0 failures/errors | Passed |
| Ruby 3.3.13 | 20 tests, 68 assertions, 0 failures/errors | Passed |
| Ruby 3.4.12 | 20 tests, 68 assertions, 0 failures/errors | Passed |

The original 17-test suite also passed directly on the VM's Ruby 3.3.8 after installing HighLine. Native modern macOS Rubies, real routers and manual terminal interaction were not validated. Existing source warnings remain; RubyGems also emits ambiguous-stringio warnings in the 3.2/3.3 environments. The matrix workflow has not run on GitHub. No changes have been committed, pushed or published.
