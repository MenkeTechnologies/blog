---
title: Inside zshrs - A zsh Port in Rust Split Into Ported Code and Extensions
date: 2026-10-30
tags: [zshrs, rust, shells, architecture]
summary: How zshrs is laid out — a mechanically enforced 1:1 port of zsh's C source, a separate extensions tree, and a fusevm bytecode core underneath both.
---
[zshrs](https://github.com/MenkeTechnologies/zshrs) is a drop-in zsh replacement written in Rust. Every command — interactive, script, function, sourced file — is compiled to [fusevm](https://github.com/MenkeTechnologies/fusevm) bytecode rather than walked as an AST, and compiled chunks are persisted across processes in rkyv images.

This post covers the layout of the codebase and the rules that keep it honest. A follow-up covers the compile pipeline and cache.

## Workspace

The repository is a 4-crate workspace:

| Crate | Role |
|-------|------|
| `zshrs` | The runtime |
| `zshrs-daemon` | IPC, HTTP, fsnotify, cache maintenance |
| `znative` | Published SDK for native Rust plugins |
| `zshrs-runtime` | Emits `libzsh.a` for AOT linking, kept separate so `cargo install zshrs` does not build it |

Shipped binaries live in `bins/`: `zshrs` (always built), `zshrs-recorder` (`--features recorder`) and `zd` (`--features zd`).

## Ported code vs extensions

The runtime source is divided into directories with different rules:

| Directory | Rule |
|-----------|------|
| `src/ported/` | Strict 1:1 port. Every `.rs` mirrors a real upstream `Src/<x>.c`; every top-level `fn` carries `/// Port of <cname>() from Src/<file>.c:NNNN`; no invented helpers; file set frozen. |
| `src/compsys/ported/` | 1:1 mirror of zsh's `Completion/` tree. Engine functions are ported to Rust; end-user completers are copied as-is and dispatched through a `_call_function` bridge. |
| `src/extensions/` | Features zsh C does not have. Must not duplicate or shadow a port. |
| `src/recorder/` | Feature-gated; every symbol is `#[cfg(feature = "recorder")]`. |

The boundary is enforced by a test, `tests/port_purity.rs`, not by convention. The lexer and parser are direct ports of `Src/lex.c` and `Src/parse.c`, and zsh's AST shape (`ZshProgram → ZshList → ZshSublist → ZshPipe → ZshCommand`) is kept as-is. The bytecode compiler, `ZshCompiler`, is the original Rust part.

Things that live in `src/extensions/` include AOT, plugin/script/autoload caches, the worker pool, ZWC helpers, and native line-editor engines ported from fish (syntax highlighting, autosuggestions, history search, autopair).

## No tree walker

The tree-walking interpreter has been removed, and tests keep it removed. `tests/tree_walker_absent.rs` asserts that the old recursive dispatch functions (`execute_simple`, `execute_pipeline`, `execute_list`, `execute_compound`, `execute_command_bg`) do not exist in the source, and that `execute_command` goes through the parser and `ZshCompiler`. `tests/no_tree_walker_dispatch.rs` pins the behavior of every construct the deleted walker used to handle.

## In-process execution

zshrs replaces many `fork + exec` paths with in-process work. From the README's comparison table:

| Operation | zsh | zshrs |
|-----------|-----|-------|
| `$(cmd)` | fork + pipe | In-process stdout capture via `dup2` |
| `cat`, `head`, `sort`, `wc`, … | fork + exec | Builtin |
| `**/*.rs` | Single-threaded `opendir` | Parallel per-subdir descent on a rayon pool |
| `compinit` | Synchronous fpath scan | Background scan on the worker pool |
| Autoload | Read + parse every time | Bytecode loaded from rkyv |

48 coreutils commands are builtins — the entries of `EXT_BUILTIN_NAMES` in `src/extensions/ext_builtins.rs` that GNU coreutils also installs.

The worker pool is configured in `~/.zshrs/zshrs.toml`:

```toml
[worker_pool]
size = 8

[glob]
parallel_threshold = 32
recursive_parallel = true
```

Extensions built on the pool include `async`/`await`, `pmap`, `pgrep`, `peach` and `barrier`, plus an `intercept` builtin for before/after/around advice on any command word:

```zsh
intercept after '_*' { echo "$INTERCEPT_NAME took ${INTERCEPT_MS}ms" }
```

The `{ … }` body form is a zshrs syntax extension; `zshrs --zsh` turns it off and rejects it the way `/bin/zsh` does.

## Compatibility checks

The project measures compatibility against reference shells rather than manuals:

- `tests/emulation_parity.rs` compares stdout and exit status of `zshrs --X` against the real shell X for the Bourne-family drop-ins (`--zsh`, `--bash`, `--ksh`, `--mksh`, `--pdksh`, `--sh`/`--posix`, `--dash`, `--ash`).
- `bins/parity-fuzz.rs` runs grammar-driven, seed-replayable snippets through both zshrs and zsh and flags divergences.
- `tests/ztst_runner.rs` runs upstream zsh's own `.ztst` files.

The README reports test counts measured on 2026-10-27:

| Suite | Tests |
|-------|-------|
| `parity` | 49,500 |
| `zsh_construct_corpus` | 396 |
| `no_tree_walker_dispatch` | 174 |
| `zsh_corpus_via_new_pipeline` | 123 |
| `zsh_parser_probe` | 87 |
| `compile_zsh_smoke` | 29 |
| `tree_walker_absent` | 8 |

## Performance as reported

The README publishes hyperfine results (release build 0.13.27, Darwin arm64) and they are mixed. A few rows, mean milliseconds:

| Workload | zshrs | zsh |
|---|---:|---:|
| Startup (no-op) | 7.4 | 4.6 |
| Arithmetic loop (100000) | 178.4 | 122.3 |
| String append (5000) | 23.8 | 52.4 |
| Command substitution (500) | 90.3 | 268.9 |
| External spawn (200) | 226.1 | 315.4 |

zshrs is ahead on command substitution, string append and external spawn, and behind on no-op startup, arithmetic loops and function calls in this run. The full table and the harness are in `bench/`.

## Install

```sh
brew tap MenkeTechnologies/menketech
brew install zshrs

# or
cargo install zshrs
```

Source and docs: [github.com/MenkeTechnologies/zshrs](https://github.com/MenkeTechnologies/zshrs).
