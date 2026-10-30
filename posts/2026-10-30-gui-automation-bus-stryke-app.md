---
title: The GUI Automation Bus — Driving GUI Apps from stryke by Verb Name
date: 2026-10-30
tags: [stryke, automation, ipc, gui]
summary: How zgui-bridge and stryke-app let a stryke script call an app's verbs, read its state, subscribe to its events, and roll back a chain of calls across several apps.
---
The GUI Automation Bus lets a stryke script call a GUI app's named verbs, read its state, and subscribe to its events, either from inside the app or from a terminal. It is semantic, not pixel-level: where `stryke-gui` moves the mouse, the bus calls `library.search` and gets rows back.

Three pieces:

| Piece | Role |
|---|---|
| `docs/GUI_AUTOMATION_BUS.md` in [MenkeTechnologiesMeta](https://github.com/MenkeTechnologies/MenkeTechnologiesMeta) | Design doc (RFC), status: shipped (Track A) |
| `zgui-bridge` | Rust crate each app links to host the bus endpoint |
| [stryke-app](https://github.com/MenkeTechnologies/stryke-app) | cdylib that provides `use App` to stryke scripts |

## The gap it closes

The apps' command palette already had an `event` step (fires one action id, no args, no result) and a `stryke` step (runs a script with no handle back into the app). A script could not get a return value, read state, subscribe to events, or reach another app. The bus adds all four.

## Host side: zgui-bridge

An app implements the `Handler` trait and calls `serve(app, handler)` once in `main`. That opens the endpoint, serves in the background, and returns an `Arc<Bridge>` the app keeps for pushing events.

| Item | Purpose |
| --- | --- |
| `Handler::call(verb, args)` | run a verb, return its value or an error string |
| `Handler::get(state)` | answer a read-only state query |
| `Handler::surface()` | the verbs/state/events manifest |
| `Handler::undo` / `Handler::rev` | compensation and reversibility class; both optional |
| `Bridge::emit(event, payload)` | push an event to every subscribed client |

Implementation choices from the crate:

- No async runtime: a listener thread plus one thread per connection.
- Dependencies are `serde` and `serde_json`, plus `interprocess` on Windows only.
- Local only. The endpoint is `$XDG_RUNTIME_DIR/zgui/<app>.sock` on Linux, `$TMPDIR/zgui/<app>.sock` on macOS, `/tmp/zgui/<app>.sock` as fallback, and the named pipe `\\.\pipe\<app>.sock` on Windows. The directory is created `0700`, the socket `0600`, and a stale socket from a crashed run is removed before bind.
- Transport-agnostic: a Tauri app forwards `call`/`get` into the webview's `ZGui.automation` surface; a JUCE app wires it over the C ABI.

Verbs are an allow-list. Only what an app registers is reachable; there is no generic eval verb.

## Wire protocol

Newline-delimited JSON. `id` correlates a reply to its request; `sub` correlates pushed events to their subscription.

```
→ {"t":"call","id":1,"verb":"library.search","args":{"q":"graphene"}}
← {"t":"reply","id":1,"ok":true,"value":[ … ]}

→ {"t":"sub","id":4,"event":"itemAdded"}
← {"t":"reply","id":4,"ok":true}
← {"t":"event","sub":4,"event":"itemAdded","payload":{ … }}

← {"t":"reply","id":9,"ok":false,"error":"no such verb: foo.bar"}
```

`get` reads a state query and `verbs` returns the typed manifest.

## Client side: use App

`stryke-app` is loaded in-process via dlopen on first `use App` and keeps one pooled connection per app, so there is no fork per call.

```stryke
#!/usr/bin/env stryke
use App

p App::list()                                     # -> ["zcite", "zreq", ...]

val $cite = App::open("zcite")
val @hits = @{ $cite->call("library.search", %{ q => "graphene" }) }
p "found ${\ scalar @hits}"

val @sel = @{ $cite->get("selection") }

$cite->sub("itemAdded")
for val $ev (@{ $cite->poll() }) { p "added: ${ $ev->{payload}{title} }" }
```

The client reads until the matching `reply` and buffers interleaved `event` frames for `poll`. On a transport error it reconnects once and retries. `App::list()` enumerates `*.sock` files in the socket directory, so on Windows it returns an empty list; dialing a known name still works.

## Transactions

A connection can open a transaction. Calls inside it are journaled, `abort` compensates them through `Handler::undo` in reverse order, and `commit` discards the journal. Each verb declares a reversibility class through `Handler::rev`, which applies only inside a transaction:

| `rev` | Inside an open transaction |
| --- | --- |
| `"inverse"` | runs, journaled, compensated on abort |
| `"pure"` | runs, not journaled |
| `"irreversible"` (default) | rejected before it runs |

Compensation is best-effort per step: every entry is attempted, and failures are returned in `failed[]` as `{seq, verb, error}`. `abort` is idempotent.

Per-app journals cannot order steps across apps, because each app has its own `seq` clock. `stryke-app` adds a client-side ledger (`src/saga.rs`) with one saga-wide `seq`:

```stryke
val $txn = App::txn()
val $ok  = eval {
    $txn->call("zftp",       "file.push",     %{ path => "app-1.7.2.tar.zst" })
    $txn->call("zcontainer", "deploy.roll",   %{ service => "web", tag => "1.7.2" })
    $txn->call("zcite",      "citation.file", %{ doi => "10.0/1.7.2" })
    1
}
if (!$ok) {
    val $r = $txn->abort()
    p "unwound ${ $r->{compensated} }; still broken: ${\ scalar @{ $r->{failed} } }"
} else {
    $txn->commit()
}
```

The first call to each app sends `begin`, so the app's own `rev` gate refuses an irreversible verb before it runs. `abort` walks the ledger in descending `seq`, sends one `undo` frame per step to the app that ran it, then sends `commit` to each app so its parallel journal is discarded without running inverses a second time. That host-side journal stays open if the orchestrating script dies mid-chain, so another process can still abort it.

## Design versus shipped

The RFC's §6 sketches `$h->on($event, $fn)` callbacks; the shipped client uses `sub` plus explicit `poll`, which matches the RFC's open-question proposal to drain events explicitly. The RFC describes `App::here()` as a direct in-process host callback with no socket; the shipped `App::here()` reads `$ZGUI_APP` and opens that app through the same socket path as `App::open`.

The RFC lists 19 apps that call `zgui_bridge::serve` today, and one JUCE host (`zpwr-daw`) through a C++ port of the transport. It records the novelty claim as a combination, "none found," low confidence.
