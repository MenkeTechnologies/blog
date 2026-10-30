---
title: Parallel Expect Playbooks with stryke-fleet
date: 2026-10-30
tags: [stryke, pty, automation]
summary: stryke-fleet is a pure-stryke package that adds transcripted PTY sessions, declarative playbooks, a recipe corpus for interactive CLIs, and parallel multi-target fan-out on top of stryke's pty builtins and pmap.
---

## What it is

[stryke-fleet](https://github.com/MenkeTechnologies/stryke-fleet) is parallel expect/PTY automation written as a pure-stryke package. It has no `[ffi]` table and no cdylib; the installed package is `stryke.toml` plus `lib/*.stk`.

The spawn/expect/send loop itself is in [strykelang](https://github.com/MenkeTechnologies/strykelang) core: `pty_spawn`, `pty_send`, `pty_read`, `pty_expect`, `pty_expect_table`, `pty_buffer`, `pty_alive`, `pty_eof`, `pty_close`, and `pty_interact` are builtins, and `pmap` provides the thread pool. The README describes what core does not provide as policy: what a step is, what a failed run returns, what an ssh login chain looks like, and what shape a transcript has. That policy lives in this package so it can be versioned independently of the language.

## The four layers

| Module | Role |
|--------|------|
| `Fleet::Session` | PTY session that records every send, match, timeout, and close |
| `Fleet::Playbook` | Declarative step lists run in order against one session |
| `Fleet::Recipes` | Step-list generators for common interactive CLIs |
| `Fleet::Fanout` | One playbook, N targets, one PTY per target in parallel |

### Session

`Fleet::Session::open` wraps a `pty_spawn` handle in a hashref with a log. `send`, `expect`, `branch`, and `close` append events, so a failed run returns the full interaction log rather than leaving a stuck process. Additions over the raw builtins include:

- `send_secret`, which transmits the text but logs `***`
- `send_control`, for Ctrl-C, Ctrl-D, and similar
- `expect_exact`, which quotemetas its argument for a literal match
- `expect_any`, which reports which of several prompts arrived
- `drain`, which reads until the child goes idle
- `transcript_text`, which dumps one `EVENT<TAB>DATA` line per event

### Playbook

A playbook is an arrayref of step hashrefs. The step keys are:

- `expect`, `branches`, and `send` (each step needs at least one of these)
- `send_matched`, which sends the result of the matching branch
- `timeout`, in seconds (default 30)
- `name`
- `optional`
- `retries` and `retry_send`
- `delay`

The first non-optional expect or branch that times out fails the run, and the error names the step. `run` returns `+{ ok, cmd, steps_run, transcript }`, plus `failed_step` and `error` on failure. `dry_run` renders the steps without spawning anything.

### Recipes

Recipes return playbook arrayrefs and never spawn anything themselves. That makes them composable with `@{...}` splices and testable without a network. `Fleet::Recipes::names` lists 48 generators. They include:

- `ssh_login`, `sudo`, `su`, `doas`
- `psql`, `mysql`, `mariadb`, `redis_cli`, `mongo`
- `telnet_login`, `sftp`, `scp`, `rsync`
- `passwd_change`, `docker_login`, `cisco_enable`, `yes_to_all`
- `restic`, `borg`, `age`, `vault_login`, `cryptsetup`, `bw_unlock`

### Fanout

`Fleet::Fanout::run` validates the steps once, then calls `pmap { Fleet::Playbook::run($_, $steps, $opts) }` over the command list. Each target gets its own PTY on its own thread, and results come back in target order. `batch` caps concurrency at K targets at a time. `ssh` builds `ssh [opts] [user@]HOST` commands from a host list.

Post-processing functions:

- `partition`, `count`, `summarize`, and `all_ok` for pass/fail totals
- `group_by_error`, which buckets failures by error string
- `group_by_output`, which buckets successes by output; its doc comment describes this as config-drift detection
- `grep_transcript`, which answers "which hosts printed X"
- `retry_failed` and `retry_until`, which re-run only the failures

## Usage

A local playbook from `examples/local_demo.stk`. It needs no network:

```stryke
use Fleet

val $r = Fleet::Playbook::run("sh", [
    +{ send   => "echo fleet-$$\n" },
    +{ expect => qr/fleet-\d+/, timeout => 10, name => "echo back" },
    +{ send   => "exit\n" },
])

p $r->{ok} ? "ok — " . $r->{steps_run} . " steps" : "failed: " . $r->{error}
```

The main use case is one login recipe run against many hosts. From `examples/parallel_ssh.stk`:

```stryke
val @steps = (
    @{ Fleet::Recipes::ssh_login(+{ password => $ENV{FLEET_PASS} }) },
    +{ send   => "uname -a; uptime\n" },
    +{ expect => qr/load average/, timeout => 15, name => "uptime output" },
    +{ send   => "exit\n" },
)

val $results = Fleet::Fanout::ssh([@hosts], [@steps], +{ ssh_opts => "-o BatchMode=no" })
val $part    = Fleet::Fanout::partition($results)
```

`ssh_login` opens with a branch table. It accepts a host-key `(yes/no)?` prompt, a password prompt, or a shell prompt directly, and it is marked optional. It then optionally answers a password and expects the shell prompt.

An installer driven by `yes_to_all`, from `examples/installer_autopilot.stk`:

```stryke
val $r = Fleet::Playbook::run($installer, [
    @{ Fleet::Recipes::yes_to_all(2) },
    +{ expect => qr/done-y-y/, timeout => 10, name => "installer finished" },
])
```

## CLI

For one-shot expect/send from the shell:

```sh
s bin/fleet.stk expect "sh -c 'sleep 1; echo ready'" ready 10   # spawn, wait, print match
s bin/fleet.stk exchange cat hello hello 5                      # spawn, send, wait
s bin/fleet.stk recipes                                         # list the recipe corpus
```

The README directs anything with branches, retries, or more than two steps to a playbook script.

## Scope boundary

The README separates Fleet from stryke's `cluster([...])` + `pmap_on`, which are persistent SSH worker pools for non-interactive remote compute. Fleet is for sessions that prompt back.

## How it's built and tested

Install with `s pkg install -g github.com/MenkeTechnologies/stryke-fleet`, or `s pkg install -g .` from a checkout.

`t/test_fleet.stk` is headless-CI safe by contract. Every PTY assertion drives a local `cat` or `sh`, and recipes are tested as data. `tests/repo-contract.sh` fails the build if any test in `t/` spawns `ssh` or calls `Fanout::ssh`. CI installs a prebuilt stryke release, runs `stryke -c` on every `.stk` file in `lib/`, `bin/`, `t/`, and `examples/`, installs the package, and runs `s test t/`.

The package is MIT-licensed.
