```
 __  __            _        _____         _                 _             _
|  \/  | ___ _ __ | | _____|_   _|__  ___| |__  _ __   ___ | | ___   __ _(_) ___  ___
| |\/| |/ _ \ '_ \| |/ / _ \ | |/ _ \/ __| '_ \| '_ \ / _ \| |/ _ \ / _` | |/ _ \/ __|
| |  | |  __/ | | |   <  __/ | |  __/ (__| | | | | | | (_) | | (_) | (_| | |  __/\__ \
|_|  |_|\___|_| |_|_|\_\___| |_|\___|\___|_| |_|_| |_|\___/|_|\___/ \__, |_|\___||___/
                                                                    |___/
                                   [ b l o g ]
```

[![CI](https://github.com/MenkeTechnologies/blog/actions/workflows/ci.yml/badge.svg)](https://github.com/MenkeTechnologies/blog/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

### `[MENKETECHNOLOGIES BLOG // STRYKE HUD THEME // GITHUB PAGES]`

The MenkeTechnologies blog. Styled with the stryke docs HUD — the same
`hud-static.css` / `hud-theme.js` / `tutorial.css` as the
[stryke docs](https://menketechnologies.github.io/strykelang/), including the
Theme / CRT / Neon toggles and the colour-scheme strip. Hosted on GitHub Pages
from `docs/` on `main`.

### [`Live site`](https://menketechnologies.github.io/blog/) &middot; [`Atom feed`](https://menketechnologies.github.io/blog/feed.xml)

---

## Table of Contents

- [\[0x00\] Publishing](#0x00-publishing)
- [\[0x01\] Writing a post](#0x01-writing-a-post)
- [\[0x02\] Markdown subset](#0x02-markdown-subset)
- [\[0x03\] Site config](#0x03-site-config)
- [\[0x04\] Output](#0x04-output)
- [\[0x05\] Layout](#0x05-layout)
- [\[0x06\] CI](#0x06-ci)
- [\[0xFF\] License](#0xff-license)

---

## [0x00] Publishing

Pages are static HTML generated from `posts/*.md` by `build.stk`
([stryke](https://github.com/MenkeTechnologies/strykelang)). Run from the repo
root (modules resolve from `./lib`):

```sh
s build.stk              # posts/*.md -> docs/
s build.stk --drafts     # include `draft: true` posts
s test t/                # renderer, front-matter and generator tests
```

Commit `posts/` and `docs/` together and push; GitHub Pages publishes `docs/`.
`make build`, `make drafts`, `make test` wrap the same commands.

## [0x01] Writing a post

One Markdown file per post in `posts/`. The file name sets the URL: an
optional `YYYY-MM-DD-` prefix is dropped and the rest is slugified, so
`posts/2026-10-30-welcome.md` → `posts/welcome.html`.

```yaml
---
title: Welcome                # required
date: 2026-10-30              # required, YYYY-MM-DD
tags: [meta]                  # optional; "a, b" also accepted; lowercased + de-duplicated
summary: One line for cards.  # optional; index cards, <meta description>, feed <summary>
draft: true                   # optional; skipped unless --drafts
---
Body in Markdown.
```

Build errors go to stderr as `blog: <file>: <reason>` and abort the build:
missing front matter, missing title, malformed date, malformed front-matter
line, duplicate slug.

## [0x02] Markdown subset

Rendered by `lib/Blog/Markdown.stk`. The core `markdown_to_html` /
`web_markdown` builtins in stryke v0.17.60 drop ordered lists, tables, images
and multi-line blockquotes, so the blog ships its own renderer.

| Block | Inline |
|:--|:--|
| ATX headings `#`–`######`, each with a slug `id` | `**bold**`, `*italic*`, `_italic_`, `~~strike~~` |
| paragraphs, `---` / `***` rules | `` `code` `` |
| ordered (keeps start number) + unordered lists, nested by indentation, tight or loose | `[text](url)` — absolute URLs open in a new tab with `rel="noopener noreferrer"` |
| blockquotes, nestable | `![alt](src)` (lazy-loaded) |
| GFM pipe tables with `:--` / `:-:` / `--:` alignment | `<https://autolink>` |
| fenced code (```` ``` ```` or `~~~`) with language tag | |

Fenced blocks tagged `stryke`, `stk`, `perl`, `pl`, `sh`, `bash`, `zsh` or
`shell` are syntax-highlighted at build time (`lib/Blog/Highlight.stk`);
colours follow the active HUD scheme. Raw HTML in a post is escaped, never
passed through.

## [0x03] Site config

The `[blog]` table in `stryke.toml`:

| Key | Use |
|:--|:--|
| `title` | header brand, `<title>`, feed title |
| `tagline` | header brand suffix |
| `description` | index subtitle, default `<meta description>`, feed subtitle |
| `base_url` | canonical URLs, feed links, absolute paths in `404.html`; no trailing slash |
| `repo` | toolbar GitHub link |
| `author` | feed `<author>` |
| `feed_limit` | newest N posts in `feed.xml` (default 20) |

## [0x04] Output

| Path | Contents |
|:--|:--|
| `docs/index.html` | all posts, newest first |
| `docs/posts/<slug>.html` | post page with older / newer navigation |
| `docs/tags/index.html`, `docs/tags/<tag>.html` | tag cloud, posts per tag |
| `docs/archive.html` | posts grouped by year |
| `docs/feed.xml` | Atom 1.0 feed |
| `docs/404.html` | Pages 404 (absolute asset paths) |
| `docs/assets/` | copied from `theme/` |
| `docs/.nojekyll` | disables Jekyll on Pages |

The output has no build timestamps: identical inputs produce byte-identical
files, and pages for deleted posts or tags are removed on the next build.

## [0x05] Layout

```
build.stk               CLI: posts/ -> docs/
lib/Blog/Site.stk       config, post loading (pmap), page set, file writes
lib/Blog/Post.stk       front matter, slug, tags, reading time
lib/Blog/Markdown.stk   Markdown -> HTML
lib/Blog/Highlight.stk  build-time code highlighting
lib/Blog/Page.stk       HUD layout + index / post / tag / archive / 404 / feed templates
theme/                  hud-static.css, hud-theme.js, tutorial.css (from strykelang/docs) + blog.css
posts/                  Markdown sources
t/                      test suite (`s test t/`)
docs/                   generated site (committed; GitHub Pages source)
```

## [0x06] CI

`.github/workflows/ci.yml` installs stryke from the latest strykelang release,
syntax-checks every `.stk` file, runs `s test t/`, rebuilds the site and fails
if the committed `docs/` differs, and checks the generated HTML for
`target="_blank"` without `rel="noopener noreferrer"` and for inline event
handlers.

## [0xFF] License

MIT — see [LICENSE](LICENSE).
