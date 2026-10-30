---
title: MCP Servers as Single Native Binaries with stryke-mcpd
date: 2026-10-30
tags: [stryke, mcp, packages]
summary: stryke-mcpd is a pure-stryke package that adds validated tool specs, crash-isolated serving, a root-jailed stock tool pack, and client helpers on top of stryke's built-in MCP support.
---

## What it is

[stryke-mcpd](https://github.com/MenkeTechnologies/stryke-mcpd) is a package for writing MCP (Model Context Protocol) servers in [stryke](https://github.com/MenkeTechnologies/strykelang). The README states the target: write the server in a few lines, `s build --release` it, ship one binary, with no Node runtime or Python venv on the target machine.

The protocol itself is not in this package. `mcp_server_start`, `mcp_connect`, `mcp_tools`, `mcp_call`, `mcp_close`, and the `tool fn` / `mcp_server "name" { ... }` desugar are strykelang core builtins. stryke-mcpd is the policy layer on top. It has no `[ffi]` table and no cdylib; the installed package is `stryke.toml` plus `lib/*.stk`.

The README states the rule for what belongs in the package:

> If a function in this library can be replaced with one builtin call, it's a bug.

## The two rules it enforces

The package exists to enforce two rules that stdio MCP servers depend on:

1. **stdout belongs to the protocol.** A stray `print` corrupts the JSON-RPC stream. `Mcpd::Server::log_to` sends diagnostics to a file, and `tests/repo-contract.sh` greps `lib/` and fails CI if any line writes to stdout.
2. **A dying tool must not kill the server.** Every `run` coderef is wrapped. A `die` inside a tool comes back to the client as an `ERROR: ...` text result, the failure is logged, and the server keeps serving.

The wrapper strips the ` at FILE line N.` suffix so the client sees only the message.

## A minimal server

From `examples/calc_server.stk`:

```stryke
use Mcpd

Mcpd::Server::serve("calc", [
    Mcpd::Schema::tool("add", "Add two numbers",
        +{ a => "number", b => "number" },
        fn { val $args = shift; $args->{a} + $args->{b} }),

    Mcpd::Schema::tool("reverse_text", "Reverse a string",
        +{ text => "string" },
        fn { val $args = shift; join("", reverse split "", $args->{text}) }),

    Mcpd::Schema::tool("always_fails", "Demonstrates the error envelope",
        +{},
        fn { die "intentional failure" }),
])
```

`serve` validates and wraps every spec, then hands the set to `mcp_server_start`. It blocks for the life of the server.

## Round trip from the client side

From `examples/round_trip.stk`, which connects to the server above over stdio:

```stryke
val $h = mcp_connect("stdio:stryke $_dir/calc_server.stk")

p "tools: " . join(", ", @{ Mcpd::Client::tool_names($h) })
p "add(2, 40)        = " . Mcpd::Client::call_text($h, "add", +{ a => 2, b => 40 })

val $err = mcp_call($h, "always_fails", +{})
p "error envelope?   = " . (Mcpd::Client::is_error($err) ? "yes" : "no")
p "server survived?  = " . (Mcpd::Client::call_text($h, "add", +{ a => 1, b => 1 }) eq "2" ? "yes" : "no")

mcp_close($h)
```

Wiring into an MCP client config is `{ "command": "stryke", "args": ["server.stk"] }`, or a built binary with no args.

## The four modules

| Module | Role |
|--------|------|
| `Mcpd::Schema` | Construction-time spec validation, arg checking, JSON Schema conversion |
| `Mcpd::Server` | `serve`, error wrapping, arg-checked serving, file-only logging |
| `Mcpd::Tools` | Stock tool pack, root-jailed |
| `Mcpd::Client` | Result-envelope extraction and call-then-extract helpers |

**Schema.** `mcp_server_start` accepts any `{name, description, parameters, run}` hashref and reports errors one tool at a time when the server starts. `Mcpd::Schema::tool` does the checks at construction time instead: the name must be an identifier, the description must be non-empty, each parameter type must be one of `string number boolean array object`, and `run` must be a coderef. `check_args` rejects missing params, undeclared extras, and mistyped numbers, arrays, and objects. `to_json_schema` and `to_tool_list` render the MCP `inputSchema` and `tools/list` payloads. `from_json_schema` and `from_tool_list` convert them back.

**Server.** Besides `serve` and `wrap`, `checked` and `wrap_all_checked` run `check_args` before the body, so a malformed call becomes an `ERROR:` envelope before the tool body runs.

**Tools.** `Mcpd::Tools::all` returns the stock pack: filesystem read, list, glob, grep, find, stat, du, head, tail, slice, hash, write, append, replace, chmod, mkdir, touch, rmdir, delete, copy, and move, plus `sh_exec`, `env_get`, `time_now`, and `sys_info`. Every filesystem path goes through `Mcpd::Tools::jail`, which normalizes `.`, `..`, and `//` lexically. A path that resolves outside the root dies, and the server wrapper turns that into an error result. `all(+{ readonly => 1 })` leaves out the mutating tools (`fs_write` through `fs_move`, and `sh_exec`). `sh_exec` takes an `allow` arrayref of permitted command words. Without `allow`, it runs any command.

From `examples/jailed_fs.stk`, an escape attempt over a live connection:

```stryke
val $esc = mcp_call($h, "fs_read", +{ path => "../../etc/passwd" })
p "escape attempt : " . (Mcpd::Client::is_error($esc)
    ? "blocked — " . Mcpd::Client::error_message($esc)
    : "LEAKED (bug!)")
```

**Client.** `text`, `texts`, `text_lines`, `content_of_type`, `is_error`, `error_message`, `tool_names`, `tool_schema`, and the `call_text` / `call_lines` / `call_texts` composites unpack the `+{content => [+{type => "text", text => ...}]}` envelope.

## CLI

```sh
s bin/mcpd.stk new myserver            # write ./myserver.stk skeleton (validated, logged, ready)
s bin/mcpd.stk serve-stock /srv/data   # stock pack jailed to /srv/data, served on stdio
s bin/mcpd.stk tools                   # list the stock tool pack
```

## How it's built and tested

Install with `s pkg install -g github.com/MenkeTechnologies/stryke-mcpd`, or `s pkg install -g .` from a checkout. No cargo step is involved.

`t/test_mcpd.stk` tests Schema, Tools, and Client as pure functions, then runs a live round trip. It generates a server script, connects over stdio, lists and calls tools, calls one that dies, and confirms the next call on the same connection still succeeds. The CI job installs a prebuilt stryke release tarball, runs `stryke -c` on every `.stk` file in `lib/`, `bin/`, `t/`, and `examples/`, installs the package, and runs `s test t/`. Separate jobs run the shell gates under `tests/`, including the stdout check.
