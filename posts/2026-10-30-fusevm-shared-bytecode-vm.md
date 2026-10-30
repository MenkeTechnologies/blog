---
title: fusevm, the Bytecode VM Under stryke and zshrs
date: 2026-10-30
tags: [fusevm, vm, jit, cranelift]
summary: How fusevm structures its opcode set, routes every execution tier through one op-semantics function, and lets stryke and zshrs share one runtime.
---
[fusevm](https://github.com/MenkeTechnologies/fusevm) is a language-agnostic bytecode VM written in Rust. Frontends compile their source to a single `Op` enum, build a `Chunk`, and hand it to `VM::run()`. The VM does not know which language produced the bytecode. The fusevm README lists zshrs and stryke first among the frontends that target it.

This post covers the op set, the execution tiers, and how the two frontends divide the shared machinery.

## Building and running a chunk

The core API is three types: `ChunkBuilder`, `VM`, and `Value`. From the README:

```rust
use fusevm::{Op, ChunkBuilder, VM, VMResult, Value};

let mut b = ChunkBuilder::new();
b.emit(Op::LoadInt(40), 1);
b.emit(Op::LoadInt(2), 1);
b.emit(Op::Add, 1);

let mut vm = VM::new(b.build());
match vm.run() {
    VMResult::Ok(val) => println!("result: {}", val.to_str()),  // "42"
    VMResult::Error(e) => eprintln!("error: {}", e),
    VMResult::Halted => {}
}
```

Execution is stack-based, with slot-indexed fast paths for locals.

## The op set

The README counts 237 opcodes across 22 sections in `src/op.rs`. Besides the usual stack, variable, arithmetic, comparison, and control-flow ops, the set has dedicated sections for shell, AWK, higher-order, and concurrency semantics:

| Section | Count | Examples |
|---|---|---|
| Shell ops | 29 | `Exec`, `PipelineBegin`, `Redirect`, `Glob` |
| AWK ops | 61 | `AwkFieldGet`, `AwkPrint`, `AwkGensub` |
| Higher-order | 5 | `MapBlock`, `GrepBlock`, `SortBlock` |
| Cooperative concurrency | 12 | `Go`, `ChanMake`, `ChanSend`, `Select` |
| Fused | 11 | `AccumSumLoop`, `SlotIncLtIntJumpBack` |
| Extension | 2 | `Extended(u16, u8)`, `ExtendedWide(u16, usize)` |

### Fused superinstructions

A frontend compiler that recognizes a common sequence can emit one fused op in its place. `AccumSumLoop(sum, i, limit)` replaces the seven-op sequence `GetSlot + GetSlot + Add + SetSlot + PreInc + NumLt + JumpIfFalse` for a counted sum loop. `SlotIncLtIntJumpBack` collapses a loop backedge into one dispatch. Each fused op removes the dispatch cycles and stack traffic of the ops it replaces.

## One function defines op semantics

fusevm has four ways to run a chunk: the interpreter, three JIT tiers, and an ahead-of-time compiler. All of them route through, or fall back to, `VM::exec_op` in `src/vm.rs`, which the source documents as "the single source of truth for op semantics."

| Tier | Entry | How it runs an op |
|---|---|---|
| Interpreter | `VM::run` | Calls `exec_op` per op in a dispatch loop |
| Linear / Block / Tracing JIT | `JitCompiler` | Emits Cranelift IR for the eligible int/float/slot subset; anything else bails or deopts to the interpreter |
| AOT | `aot::compile_object` | One Cranelift block per op; unspecialized ops call `exec_op` through an `extern "C"` shim |

A new op is implemented once, in `exec_op`, and every tier inherits it. The JIT and AOT paths only specialize the scalar ops; string, array, hash, and host ops stay in the interpreter.

## The JIT tiers

The JIT uses Cranelift 0.130 behind the `jit` feature flag and emits native x86-64 or aarch64. A chunk is served by one of three tiers:

| Tier | Trigger | Coverage |
|---|---|---|
| Linear | First call, if eligible | Straight-line expression chunks |
| Block | 1 invocation (default) | Whole-chunk CFG: loops, branches, fused backedges, globals |
| Tracing | 50 backedges through a loop header | Recorded hot path, type-specialized, deopts on guard miss |

Both thresholds can be set per process with `FUSEVM_JIT_BLOCK_THRESHOLD` and `FUSEVM_JIT_TRACE_THRESHOLD`, or per thread through `TraceJitConfig`.

On a tracing guard miss, the VM rebuilds the value stack and any inlined call frames, then resumes `exec_op` at the deopt IP.

The `jit-disk-cache` feature persists compiled code to `~/.cache/fusevm-jit`, so codegen is skipped across process restarts. The `aot` feature lowers a whole chunk to a relocatable object through `cranelift-object` and links it against the runtime into a standalone executable; each frontend's `--build` calls into it.

## How stryke and zshrs share it

Both frontends emit the same `Op` enum, and each reaches language-specific behavior through a different extension path.

**zshrs** emits no extended ops. Shell semantics go through the `ShellHost` trait, which handles `Glob`, `TildeExpand`, `CmdSubst`, `Redirect`, pipelines, traps, and the other shell ops. zshrs supplies the real implementation; without one the VM uses stubs that keep the stack balanced. Builtins lower to `CallBuiltin(id, argc)` with IDs from `shell_builtins.rs` plus zshrs's own.

**stryke** reserves two disjoint blocks of `Extended` op IDs: one at `0x0000` (`ext_ops` in `fusevm_bridge.rs`) and one at `0x1000` (`nops` in `fusevm_native.rs`). The VM dispatches them through a handler the frontend registers with `VM::set_extension_handler`. Because each frontend owns its own ID space, the tables do not conflict.

stryke's adoption is partial. Its README describes `fusevm_bridge.rs` as a tier-0 JIT that sends string-bearing segments to fusevm's block JIT, while stryke's own block JIT handles pure-integer segments. The repo's migration checklist sets the goal of retiring stryke's own `vm.rs` and `jit.rs`, and reports 126 of 362 stryke `Op` variants with native fusevm lowering.

The two also share a process. stryke depends on zshrs as a library, so both must resolve to one fusevm version. stryke's `Cargo.toml` requires `fusevm = "0.26.7"`, the same minor zshrs uses, and explains why: fusevm defines about 54 `#[no_mangle]` symbols, and two semver-incompatible copies in one dependency graph fail to link on duplicate symbols.

## Install

```sh
cargo add fusevm --features jit   # with Cranelift JIT
cargo add fusevm                  # interpreter only
```

Source and benchmarks are in the [fusevm repository](https://github.com/MenkeTechnologies/fusevm).
