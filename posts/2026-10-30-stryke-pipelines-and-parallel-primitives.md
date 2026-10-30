---
title: Pipelines, Threading, and Parallel Primitives in stryke
date: 2026-10-30
tags: [stryke, parallelism, pipelines, rust]
summary: How stryke combines Perl 5 syntax with pipe-forward, a threading macro, and rayon-backed parallel builtins.
---
[stryke](https://github.com/MenkeTechnologies/strykelang) is a dynamic language implemented in Rust. The README describes it as an interpreter that "parses and executes Perl 5 scripts with rayon-powered work-stealing primitives across every CPU core." On top of the Perl 5 base it adds pipe-forward, a threading macro, implicit block parameters, and a family of parallel builtins. A `--compat` flag turns all of those extensions off for running unmodified Perl.

This post covers the pipeline syntax and the parallel primitives. Every example below was run against stryke v0.17.60 with `stryke -e`.

## Execution model

The README's architecture section lays out the pipeline: lexer, recursive-descent and Pratt parser, compiler to bytecode, then a match-dispatch VM with a Cranelift block JIT. Hot subs are handed to the JIT after a configurable number of VM invocations (`STRYKE_JIT_SUB_INVOKES`, default 50), and `--no-jit` disables it. Values are a NaN-boxed `u64` (`StrykeValue`) that holds immediates inline and points at `Arc<HeapObject>` for strings, arrays, hashes, and the rest.

Warm starts skip lex, parse, and compile by reading from an rkyv shard at `~/.stryke/scripts.rkyv`, which is mmapped for zero-copy lookup.

String-bearing code segments are lowered to [fusevm](https://github.com/MenkeTechnologies/fusevm), the bytecode VM stryke shares with zshrs. Moving all execution onto fusevm is in progress; the migration checklist in the repo reports 126 of 362 stryke `Op` variants lowered.

## Pipe-forward: `|>`

`|>` is desugared at parse time. It passes the left side as the **first** argument of the call on the right, and associates left. `map`, `grep`/`filter`, `sort`, and `e` accept a blockless expression on the right-hand side:

```stryke
1..5 |> map $_ * $_ |> join "," |> p
# 1,4,9,16,25
```

Per the README, `|>` binds looser than `||` and tighter than `?:` and `and`/`or`/`not`, so `$x + 1 |> f` parses as `f($x + 1)`.

## The threading macro: `~>`

`~>` (aliases `thread`, `t`, `->>`) chains stages without repeating `|>`. Stages can be bare function names, functions that take a block, parenthesized calls with `_` as the placeholder, or anonymous blocks written `>{ }`. Inside blocks, bare `_` is the topic (`$_`), and `_1` is the second positional.

```stryke
~>1:10map{_*2}fi{_>5}sum p
# 104
```

Block-taking stages chain directly, and `|>` ends the macro:

```stryke
@data = 1..20; ~> @data grep{_ % 2 == 0} map{_ * _} sort{$_1 <=> $_0} |> join "," |> p
# 400,324,256,196,144,100,64,36,16,4
```

Anonymous blocks and placeholder calls:

```stryke
~> 100 >{_ / 2} >{_ + 10} >{_ * 3} p
# 180

fn add2 { $_0 + $_1 }
~> 10 add2(_, 5) add2(_, 100) p
# 115
```

The README's guidance: use `~>` when most stages take blocks, and `|>` for blockless expressions and unary functions.

## Parallel primitives

Every parallel builtin runs on rayon's work-stealing pool. The README states that each parallel block runs in its own interpreter context with captured lexical scope, and `-j N` sets the thread count. The parallel forms slot into pipelines like the sequential ones:

```stryke
val @data = 1..10; val @d = @data |> pmap $_ * 2; p join ",", @d
# 2,4,6,8,10,12,14,16,18,20

val @data = (5,3,9,1); val @s = @data |> psort { _ <=> _1 }; p join ",", @s
# 1,3,5,9

val @n = 1..100; val $s = @n |> preduce { _ + _1 }; p $s
# 5050
```

`pmap_reduce` fuses the map and the reduction:

```stryke
val @n = 1..10; val $s = @n |> pmap_reduce { _ * 2 } { _ + _1 }; p $s
# 110
```

`fan_cap N { ... }` runs a block N times in parallel with the index as the topic and returns results in index order:

```stryke
val @r = fan_cap 8 { _ * _ }; p join ",", @r
# 0,1,4,9,16,25,36,49
```

### Streaming

`pmaps`, `pgreps`, and `pflat_maps` are lazy. The README describes them as bounded-memory iterators that emit output as it completes, so an unbounded source can be cut off with `take`:

```stryke
range(0, 1e9) |> pmaps { _ * 2 } |> take 3 |> ep
# 0
# 2
# 4
```

### Pipeline objects

`par_pipeline` builds a rayon-backed chain; `par_pipeline_stream` runs stages concurrently over bounded crossbeam channels and, per the README, does not preserve order. In v0.17.60 the method-call form works for both:

```stryke
val @r = ((1..20) |> par_pipeline)->filter({ _ > 10 })->map({ _ * 2 })->collect; p join ",", @r
# 22,24,26,28,30,32,34,36,38,40

val @r = ((1..1_000) |> par_pipeline_stream)->filter({ _ > 995 })->map({ _ * 2 })->collect(); p join ",", sort { $a <=> $b } @r
# 1992,1994,1996,1998,2000
```

## Shared state: `varsync`

Workers get a copy of captured lexicals by default. A plain `my` counter incremented inside `pfor` is unchanged when the loop finishes:

```stryke
my $c = 0; pfor { $c++ } 1..10; p "c=$c"
# c=0
```

To share state you opt in with `varsync`, which wraps the variable in `Arc<Mutex>`. Compound operators (`++`, `+=`, `.=`, `|=`, `&=`) hold the lock for the whole read-modify-write:

```stryke
varsync $counter = 0; fan 10000 { $counter++ }; p $counter
# 10000

varsync $n = 0; pfor { $n += _ } 1..100; p $n
# 5050
```

## Further reading

The [strykelang README](https://github.com/MenkeTechnologies/strykelang) also covers channels (`pchannel`, `pselect`), `barrier`, `ploop`/`pwhile`, `ppool`, the parallel file-IO builtins (`par_lines`, `par_walk`, `glob_par`), and `pmap_on` for spreading a map across an SSH worker pool. `stryke docs pmap` opens the built-in reference at that topic.
