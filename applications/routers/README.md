# expect4r-routers

Router automation built on the separate `expect4r` terminal dialogue engine.
This gem depends on the core; the core has no router dependency.
Ruby 4.0.6+ on macOS/Linux. IOS, IOS-XR (`:iox`) and Junos behavior is
simulator-tested; real device validation remains outstanding.

```ruby
require 'expect4r_routers'

Expect4rRouters.open(:ios, host: 'lab-router', user: 'lab',
                     password: -> { ENV.fetch('ROUTER_PASSWORD') }) do |router|
  router.enable(password: -> { ENV.fetch('ENABLE_PASSWORD') }) if router.user?
  puts router.show!('version').output
  router.configure do |config|
    config.command 'router bgp 65000'
    p router.mode         # :config
    p router.config_depth # 1 (configuration root is 0)
    p router.config_path  # ["router bgp 65000"]
    config.command 'address-family ipv4'
    p router.config_depth # 2
    router.up
    router.top
  end
  result = router.ping('192.0.2.1', count: 5, minimum_success: 100)
  p [result.status, result.transmitted, result.received, result.loss_pct]
end
```

## Context

Cisco modes are `:user`, `:admin` (privileged EXEC), and `:config`.
Junos operational mode is `:operational`; it does not imply unrestricted user
permissions. Helpers include `user?`, `admin?`, `operational?`, `exec?`, `config?`,
`in?`, `config_depth`, `config_path`, and `config_submode`.

Depth is measured from configuration root, not inferred from prompt hyphens.
Cisco context combines confirmed command transitions with observed prompts;
Junos uses `[edit ...]` hierarchy markers and recognized hierarchy grammar.
Unknown context has a nil depth; it is never invented. `config_lvl?` preserves the
old convention (root 1, outside config -1). Raw session writes invalidate tracked
context until a prompt is observed again; unknown Cisco submode depth cannot be
recovered from a prompt alone. `top` and `up` reject unsafe navigation.
`with_mode` scopes supported transitions and restores privilege when possible.
IOS-XR's separate admin plane is not implemented by the IOS `enable` operation.

## Commands and ping

`exec` returns a structured result; `exec!` raises on failure. `show`/`show!`
accept the text after `show` and add Cisco `do` or Junos `run` in configuration.
Paging markers, echoed command and terminal prompt are removed; remaining output
preserves bytes and whitespace. Timeouts/disconnects mark the session uncertain;
use explicit `resynchronize!` or reconnect. Commands are never automatically replayed.

`ping` returns counts, loss percentage, optional RTT statistics and its command
result. `ping!` raises `Expect4rRouters::PingError` on failure. Packet loss, parse
failure, timeout, disconnect and device rejection remain distinguishable.
Common options include `count`, `size`, `source`, `protocol`, `minimum_success`,
and `command_timeout`. Legacy aliases include `repeat_count`, `datagram_size`,
`source_address`, and `pct_success`.

Cisco uses the extended interactive dialogue for options such as `probe_timeout`,
`tos`, `df`, `pattern`, and sweep sizes. Junos uses its native command with
`rapid`, `wait`, `ttl`, `interval`, `routing_instance`, and logical-system/router
options. Unsupported options fail before transmission: Junos `wait` is not
silently substituted for Cisco per-probe timeout. A ping from configuration uses
`do`/`run` while preserving its tracked location.

Candidate configuration uses exclusive entry and explicit `config.commit`;
uncommitted changes are discarded when leaving the scope. IOS changes apply
immediately and have no implied rollback. Default prompts assume Cisco `#`/`>`
and one trailing space on Junos; customized prompts need exact `prompt:` settings.

From the repository root:

```sh
rv run bundle exec rake routers
rv run bundle exec ruby applications/routers/examples/local_router.rb
rv run bundle exec rake package_routers
```

The CLI simulator is an independent application test fixture, not part of either
gem's runtime. No router credentials or network connection are needed for tests.
