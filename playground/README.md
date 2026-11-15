# Linux dialogue playground

Real command-line applications for expect4r v2, using Ruby 4.0.6 on native ARM64 or AMD64 Linux. No routers required.

| Program | What to exercise |
| --- | --- |
| OpenSSH client/server | Password challenge, sensitive writes, shell prompt, timeout, EOF, manual handoff |
| Telnet client/BusyBox server | Login/password sequence, nested PTY, shell dialogue |
| SQLite | Main prompt, multiline continuation prompt, result matching |
| Python | REPL continuation, indentation, blank-line termination |
| Bundled router simulator | IOS/IOS XR/Junos modes, config depth, show/ping |
| Local replay example | Record a real PTY dialogue, replay one byte at a time |

## Build and start

From the repository root on a Linux Docker host:

```sh
docker build -f playground/Dockerfile -t expect4r-v2-playground .
docker run -d --name expect4r-v2-playground expect4r-v2-playground
docker exec -it expect4r-v2-playground bash
```

Inside the container:

```sh
sh check.sh
ruby dialogues.rb ssh
ruby dialogues.rb telnet
ruby dialogues.rb sqlite
DEBUG=1 ruby dialogues.rb ssh
ruby dialogues.rb python
MANUAL=1 ruby dialogues.rb ssh
MANUAL=1 ESCAPE_KEY=C-x ruby dialogues.rb telnet
RECORD=/tmp/ssh.jsonl ruby dialogues.rb ssh
ruby /src/script/replay_info.rb /tmp/ssh.jsonl
ruby /src/examples/local_replay.rb
ruby /src/applications/routers/examples/local_router.rb
```

Manual mode gives you the authenticated shell. Press Ctrl-] (or your chosen key) to return to Ruby; the demo sends Ctrl-C to interrupt any foreground command, recovers the shell prompt, and resumes automation. This demo policy allows commands such as `dd` or `sleep 100` during manual mode; `interact` itself does not interrupt programs when it returns. Leave the remote shell running until handoff: typing `exit` closes it instead.

Set `DEBUG=1` to print matching diagnostics to stderr. Edit `/opt/playground/dialogues.rb` in your own derived image, or mount the local playground directory at `/opt/playground` when starting the container, to experiment with patterns, timeouts, and debug settings. Core and router gems are installed from the checked-out source during image build; rebuild after changing them.

Direct clients are also available:

```sh
ssh -p 2222 -o UserKnownHostsFile=/run/playground-known-hosts lab@127.0.0.1
telnet -K 127.0.0.1 2323
sqlite3 :memory:
python3 -q
```

Lab credentials: `lab` / `lab-password`. Servers bind to container loopback only; no host ports are published. SSH verifies the locally generated host key. This disposable lab intentionally includes plaintext Telnet. Host keys are generated on first startup; recordings survive a restart but disappear when the container is removed unless written to a mounted directory. Recordings containing passwords require explicit substitutions for strict replay; see `docs/REPLAY.md`.

Stop/start/remove from the host:

```sh
docker stop expect4r-v2-playground
docker start expect4r-v2-playground
docker rm -f expect4r-v2-playground
```

References: [OpenSSH](https://man.openbsd.org/ssh), [BusyBox](https://www.busybox.net/downloads/BusyBox.html), [SQLite CLI](https://www.sqlite.org/cli.html).

## Verified

Built and exercised on the ARM64 Linux VM with Docker and Ruby 4.0.6: all four application checks passed, as did the bundled local replay and router simulator examples. SSH recording was loaded and its password write was marked redacted. An initial human SSH handoff exposed a demo recovery bug when `dd` remained in the foreground; the demo now interrupts the foreground command before waiting for a prompt.

The user subsequently confirmed the corrected manual SSH scenario: `dd` was interrupted, control returned to Ruby, and `SSH_CHECK_PASSED` was printed. Driven PTY checks also passed the foreground-`dd` handoff over SSH and Telnet. Manual Telnet handoff has not been human-confirmed.

Real IOS, IOS XR, and Junos devices are unavailable for validation. Router simulator and replay coverage exercise application behavior but do not establish compatibility with actual vendor firmware. Real-device validation remains outstanding; it does not block use of this generic Linux playground.
