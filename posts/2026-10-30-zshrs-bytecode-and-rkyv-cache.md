---
title: How zshrs Compiles Shell Code and Caches It in rkyv
date: 2026-10-30
tags: [zshrs, rust, bytecode, caching]
summary: The zshrs pipeline from zsh source to fusevm bytecode, its tiered JIT, and the rkyv cache that lets later processes skip lexing, parsing and compiling.
---
[zshrs](https://github.com/MenkeTechnologies/zshrs) does not interpret an AST. Every command is lexed and parsed by ports of zsh's C front end, compiled to [fusevm](https://github.com/MenkeTechnologies/fusevm) bytecode, and run on a VM. Compiled chunks are persisted in rkyv files, so a script or autoload function compiled by one process can be loaded by the next without going through the front end again.

## The pipeline

From the README:

```
Interactive command  ──► lex::zshlex ──► parse::parse ──► ZshCompiler ──► fusevm::Op ──► VM::run()
Script file (first)  ──► lex::zshlex ──► parse::parse ──► ZshCompiler ──► VM::run() ──► persist rkyv shard
Script file (cached) ──► index.rkyv + mmap shard ──► deserialize Chunk ──► VM::run()
Autoload function    ──► autoloads.rkyv ──► deserialize Chunk ──► VM::run()
```

`lex::zshlex` and `parse::parse` are ports of `Src/lex.c` and `Src/parse.c`. `ZshCompiler` is the only original piece of the front end. It targets the same `Op` enum that [strykelang](https://github.com/MenkeTechnologies/strykelang) uses, so both languages share fused superinstructions, extension dispatch and the Cranelift JIT path.

## Execution tiers

Inside `fusevm::VM::run()` a chunk lands on one of several tiers:

| Tier | What | When |
|------|------|------|
| rkyv image hit | Skip lex/parse/compile | Warm script runs |
| Block JIT | Native code via Cranelift | Loops, conditionals |
| Linear JIT | Native code via Cranelift | Straight-line arithmetic |
| Interpreter | Jump table + superinstructions | Builtins, I/O, strings |

Enabling the JIT does not mean a given chunk is JIT-compiled. `zshrs --tiers` runs a script and then asks fusevm which tier took each chunk, using fusevm's own predicates (`is_block_eligible`, `block_jit_is_compiled`, `trace_is_compiled`, `find_jit_region`). For chunks that reached neither JIT tier it lists the op kinds responsible:

```sh
zshrs --tiers script.zsh
```

## Cache layout

Everything lives under `$ZSHRS_HOME` (default `~/.zshrs/`):

| Path | Contents |
|------|----------|
| `index.rkyv` | Index: fq_name → shard id, generation, byte offset |
| `images/{hash8}-*.rkyv` | Mmap-ready shards (system, completions, plugins, scripts, `.zshrc`, …) |
| `autoloads.rkyv` | One compiled program per autoloaded function |
| `scripts.rkyv` | One chunk per script run; per-event chunks for sourced files |
| `deparse.rkyv` | Deparsed function bodies (what `$functions` prints) |

The SQLite files in the same directory — `catalog.db` and the views used by `dbview` — are read-only mirrors for inspection. The README states they are never consulted for cache hit/miss or execution. `history.db` and `zshrs_history.db` hold history and are unrelated to bytecode caching.

## Invalidation keys

Each store keys its entries on what determines the compiled output:

- **Autoloads**: function name, the resolved fpath directory, a SHA-256 of the exact definition text, and the identity of the `zshrs` binary that compiled it. An edited function recompiles. Each entry also records what the `$fpath` search found, so a later load can skip the search while the directory is still on `fpath` and those files are unchanged.
- **Scripts**: path, mtime, build, and the alias/option state the first run started from. A file that changes aliases or options itself is not stored.
- **Deparse**: SHA-256 of the name, body text and the option state the body is re-lexed under, plus the binary identity.

The autoload cache is bypassed for `ksh_autoload`-style bodies and for `autoload` without `-U`, because there the compiled program is not a function of the file's bytes alone.

## Measured effect

The README reports two sets of numbers.

For `_git` (424 KB of shell): the first `git <tab>` in a process goes from **1.06 s to 0.56 s** once the chunk is cached; decoding the cached 4.6 MB chunk costs **229 µs** versus **318 ms** to parse and compile the file.

The README's cold vs warm comparison (it does not name the workload):

```
Cold (cache miss):  717ms  — lex + parse + compile + cache write + execute
Warm (cache hit):     7ms  — deserialize + execute
```

## Prewarming

Autoload entries are written through on first call, one per function actually used. To compile a whole directory up front:

```zsh
zshrs --prewarm-autoloads            # every dir on $fpath
zshrs --prewarm-autoloads DIR ...    # just these
zd prewarm [DIR ...]                 # via the daemon
prewarm-autoloads [DIR ...]          # as a builtin inside a shell
```

Entries already current are skipped by SHA-256, so a re-run after adding one plugin compiles only the new completers. The README gives a sizing budget of roughly 6x the source size: a 13k-completer directory compiles to 165 MB in 35 s on a debug build. `zshrs-recorder` runs this pass at the end of every recording (`--no-prewarm` skips it); it must not run beside a live ZLE because the parser uses process-global lexer state.

## Inspecting the cache

`dbview` reads the mirrors without SQL:

```zsh
dbview                        # tables + row counts
dbview autoloads _git         # source, body, bytecode status
dbview scripts                # compiled sourced scripts
```

Source: [github.com/MenkeTechnologies/zshrs](https://github.com/MenkeTechnologies/zshrs).
