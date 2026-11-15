# Migrating from expect4r 0.x

The v2 default entry point is a new general-purpose API. Ruby >=4.0.6 is required.
To keep an existing script on the old API, change its require to
`require 'expect4r/legacy'` and add `legacy/lib` to the load path. This source-only
compatibility tree and its HighLine dependency are excluded from the new gems. Legacy and modern sessions cannot coexist in a Ruby
process because the old implementation changes global IO/Kernel behavior.

| Legacy | Modern |
|---|---|
| `Ios.new_ssh(...)` followed by `login` | `Expect4rRouters.open(:ios, host: ..., user: ..., password: ...)` |
| `exp_send` with implicitly split/trimmed lines | `send_line` for one exact line; `write` for bytes; `exec_many` for explicit arrays |
| `interact('C-x')` | `session.interact(escape_key: 'C-x')`; raw `escape:` sequences also remain supported |
| Nested output arrays | `CommandResult#output` byte String, or a borrowed streaming sink |
| `expect(pattern, seconds, matches)` | `expect(pattern, timeout: seconds)` or an ordered pattern/action block |
| Exceptions with `err_msg` | Ordinary useful `message`, `cause` and structured `result` |
| Fixed-key password cipher | Lazy credential provider and explicitly redacted outgoing values |
| Implicit commit | Explicit `config.commit` inside an exclusively owned candidate scope |
| Reconnect and retry | Uncertain-state reporting and explicit recovery; no automatic replay |
| Global debug switches | Per-session Logger and optional byte diagnostics |

The old files remain unchanged except for the loader boundary; they are not the
implementation of the new API. Legacy tests run separately with `rake legacy`.
Tests under `test/core` and `applications/routers/test` exercise only the new API.

The local router simulator supports reproducible development. The Linux playground
also verifies real local SSH and Telnet dialogues, including rejected SSH login and
remote-shell disconnection. Device firmware, privilege escalation, noisy banners
and unusual prompts still need device-specific verification before migrating
production scripts.

Router scripts now install `expect4r-routers`, require `expect4r_routers`, and use
`Expect4rRouters` for router classes, command results and application exceptions.
The generic engine remains under `Expect4r`. There is no router alias in the core.
