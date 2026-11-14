# Mac terminal interaction check

No routers, VM, SSH credentials or remote changes are involved. This starts a local
Ruby child with a small command prompt.

From Mac Terminal:

```sh
cd /Users/jesnault/Documents/Codex/2026-11-12/new-chat-2/expect4r
rv run bundle install
rv run bundle exec ruby examples/manual_interact.rb
```

1. At `manual>`, type `manual-check` and press Enter.
2. Confirm `MANUAL_OK` appears, then wait for the next `manual>` prompt.
3. Hold Control and press `]` once. Do not type the characters `C-]`.
4. Confirm these markers appear and you return to your shell:

```text
RETURNED_TO_RUBY
TERMINAL_RESTORED
INTERACT_CHECK_PASSED
```

The script checks that the terminal's saved `stty` settings are restored, sends an
automated command to the same child, verifies its response, and exits/reaps it.
The child tracks the manual step, so skipping it does not produce a false success.

Repeat with Ctrl-X if desired:

```sh
rv run bundle exec ruby examples/manual_interact.rb C-x
```

Both keys passed a driven nested-PTY check on the Mac with rv Ruby 4.0.9. This still
needs the human Terminal check above; no interactive test should be inferred from
an ordinary non-TTY CI run. The harness rejects non-TTY input/output.

If a marker is missing, keep the output and report which step failed. Do not treat
returning to a shell alone as proof of successful resumed automation.
