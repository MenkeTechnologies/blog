---
title: stryke web — A Rails-Shaped Framework for stryke
date: 2026-10-30
tags: [stryke, web, framework, rust]
summary: What the stryke web generator and runtime ship today, and which parts of the design doc are still targets.
---
stryke web is the web framework for [strykelang](https://github.com/MenkeTechnologies/strykelang). It has two halves: a Rust CLI, `s_web`, that generates `.stk` source for a new app, and a set of `web_*` runtime builtins inside the stryke interpreter that serve it. The design doc is `docs/WEB_FRAMEWORK.md`; the generator reference is `stryke_web/README.md`.

The design doc marks its own status: Phase 0 shipped, most of Phase 1 shipped, Phase 2 mostly deferred, Phase 3 not started. This post follows that split.

## Architecture

| Layer | Language | Location |
|---|---|---|
| Generator CLI (`s_web new`, `g`, `s`, `db`, `routes`) | Rust | `stryke_web/` |
| Generated app code (`config/routes.stk`, controllers, models) | stryke | the user's app directory |
| Framework runtime (`web_route`, `web_render`, ORM, migrations) | Rust builtins | `strykelang/web.rs`, `strykelang/web_orm.rs` |

The `stryke_web` crate opts out of the parent workspace with its own `[workspace]` table, so it builds independently of the interpreter. Its only runtime dependencies are `clap` and `heck`.

## Shipped: the generator

```sh
s_web new myblog
cd myblog
s_web g scaffold Post title:string body:text published:bool
# routes.stk — add `web_resources "posts"`
s_web db migrate
bin/server
# open http://localhost:3000/posts
```

`s_web g scaffold` writes a model, a migration, a 7-action controller, and 5 ERB views. The generated controller calls model class methods that delegate to the `web_model_*` builtins:

```stryke
fn index {
    my $posts = Post::all()
    web_render(template => "posts/index", locals => +{ posts => $posts })
}

fn create {
    Post::create(web_params())
    web_redirect("/posts")
}
```

Other generators: `controller`, `model`, `migration`, `app PRESET`, `auth`, `admin`, `api`, `mailer`, `job`, `channel`, `docker`, `ci`, `pwa`. `s_web new` also takes flags that run several of these at once:

```sh
s_web new myapp --app everything --theme dark --auth --admin --migrate
```

Presets include `blog`, `ecommerce`, `saas`, `cms`, `forum`, `crm`, `helpdesk` and others. Themes include `simple`, `dark`, `pico`, `bootstrap`, `tailwind`, and four CSS-only neon themes (`cyberpunk`, `synthwave`, `terminal`, `matrix`). `--docker`, `--ci`, and `--pwa` add a multi-stage Dockerfile, a GitHub Actions workflow that runs migrate + boot + a `/health` smoke check, and a PWA manifest plus service worker.

## Shipped: the runtime

Routing is a set of builtins called from `config/routes.stk`:

```stryke
web_root "welcome#index"
web_route "GET    /path", "controller#action"
web_resources "posts"           # full REST scaffold (7 routes)
```

The runtime surface, grouped:

- **Request/response**: `web_params`, `web_request`, `web_render` (html/text/json/template), `web_redirect`, `web_set_header`, `web_status`. An action that calls neither `web_render` nor `web_redirect` renders `app/views/{resource}/{action}.html.erb`.
- **Templates**: ERB with `<%= %>`, `<% %>`, `<%# %>`, `<%- -%>`, layouts, and `web_render_partial`. Control structures can span tags because the engine compiles all segments into one stryke program before running it.
- **Data**: SQLite by default (`web_db_connect`, `web_db_query`, `web_db_execute`), the `web_model_*` CRUD set, pagination, LIKE search, soft delete, counter caches, single-IN-query eager loading (`web_model_with`), and transactions.
- **Migrations**: `web_create_table`, `web_add_column`, `web_remove_column`, `web_drop_table`, `web_migrate`/`web_rollback`, tracked in `schema_migrations`.
- **Jobs**: database-backed queue (`web_jobs_init`, `web_job_enqueue`/`dequeue`/`complete`/`fail`).
- **Security and auth**: CSRF meta tag, `web_security_headers`, `web_permit` strong params, cookie sessions and flash, JWT (HS256), TOTP, token-bucket rate limiting, signed time-limited tokens, `web_can`.
- **APIs**: `/openapi.json`, Swagger UI at `/docs`, and Redoc at `/docs/redoc` are served from the live route table with no app code. JSON:API envelope helpers and `web_bearer_token` are included.
- **Streaming**: SSE via `web_sse_event` and `web_render_stream`.

`s_web build` generates a Rust wrapper crate that embeds every `.stk` file with `include_str!`; `cargo build --release` inside it produces one binary containing the framework, the app, and statically linked SQLite. The README reports one such build at 136 MB on macOS arm64.

## Shipped behavior that differs from the design doc

Some shipped pieces are simpler than the doc's target form:

| Area | Design doc target | Shipped |
|---|---|---|
| Template output | originally `#{ expr }`, compiled AOT via Cranelift | ERB `<%= %>`, compiled to a stryke program at request time |
| Routing DSL | `route :GET, "/", home#index`, `resources :posts` | `web_route` / `web_resources` / `web_root` builtins |
| Password storage | Argon2id | SHA-256 + salt (`web_password_hash`) |
| JSON | simd-json | `serde_json` |
| ORM | joins, scopes, callbacks | single-table chains; joins/scopes pending |

The template change is recorded in the doc's Resolved Decisions (2026-05-01): ERB replaced `#{}` for visual parity with Rails.

## Not shipped yet

From the doc's phase list, deferred or not started:

- HTTP/2 via `h2` and TLS via `rustls`.
- WebSockets and the Channel abstraction (generators scaffold channel stubs only).
- glommio + io_uring thread-per-core runtime, per-core sharding.
- Mailer runtime (SMTP); the generator writes the structure.
- Polished hot reload, TechEmpower harness, public benchmark dashboard.
- Phase 3: HTTP/3 default-on, kTLS, custom SIMD HTTP parser, wasm32-wasi edge target.

`s_web console` is marked pending a stryke `--repl` flag.

## Performance: targets, not measurements

The design doc has a performance table: 500k req/s plaintext for Phase 0, rising to 6M+ for Phase 3, plus cold-start and memory targets. These are design targets. For Phase 0 the doc says the number is "still subject to TechEmpower-style validation", and the Phase 1 targets are "pending Phase 2 perf work." No TechEmpower results are published in the repo. Local benchmarks run through `s bench`.

The one wall-clock figure in the generator README is about scaffolding, not serving: about 0.45 s to generate and migrate the `everything` preset.

Source: `docs/WEB_FRAMEWORK.md`, `stryke_web/README.md`, and `strykelang/web.rs` in [strykelang](https://github.com/MenkeTechnologies/strykelang).
