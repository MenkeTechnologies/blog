---
title: zpwr, a Terminal Environment Behind One Verb Dispatcher
date: 2026-10-30
tags: [zpwr, zsh, tmux, dotfiles]
summary: How zpwr installs, where its files live, and how its single dispatcher command exposes diagnostics, profiling, and snapshot tooling.
---
[zpwr](https://github.com/MenkeTechnologies/zpwr) is a terminal environment built on zinit. It configures the shell, tmux (ztmux), vim, completion and keybindings from a single repository. The README credits Hashrocket's Dotmatrix as the original fork point. The installer sets [zshrs](https://github.com/MenkeTechnologies/zshrs) as the login shell; stock zsh remains supported.

Most of the environment is reached through one command: `zpwr <verb>`.

## Installing

One line:

```sh
sh -c "$(curl -fsSL raw.githubusercontent.com/MenkeTechnologies/zpwr/main/install/s)"
```

`install/s` is a wrapper around the manual path:

```sh
git clone --depth 1 -- https://github.com/MenkeTechnologies/zpwr.git ~/.zpwr && cd ~/.zpwr/install && ./zpwrInstall.sh
```

The installer confirms what it will install and overwrite before it runs. It builds the Rust toolchain components with cargo in the background, adds zshrs to `/etc/shells` and runs `chsh`. If zshrs is not on `PATH` when cargo finishes, it falls back to stock zsh. Zinit installs plugins on the first shell after install.

`zpwrInstall.sh` takes these flags:

| Flag | Effect |
|---|---|
| `-a` | Install all dependencies |
| `-c` | Copy just configs |
| `-n` | Do not start ztmux at end of installer |
| `-s` | Skip main section |
| `-h` | Display help |
| `-V` | Display script version |

`-c` is the minimal install: configs only, no dependencies. The scripts in `~/.zpwr/install` can then be run one at a time.

## Layout

Everything lives under `~/.zpwr` (the `ZPWR` variable). `~/.zshrc`, `~/.vimrc`, `~/.tmux.conf` and the other configs are symlinked into `$HOME`. Previous configs are archived under `~/.zpwr/local`.

Top-level directories at `origin/main`:

| Path | Contents |
|---|---|
| `autoload/` | autoloaded functions, split by `common`, `darwin`, `linux`, `fzf`, `comps`, `comp_utils`, `systemctl` |
| `env/` | environment and the verb table (`env/zpwr.zsh`) |
| `install/` | installer scripts |
| `scripts/` | standalone scripts |
| `tests/` | zunit test files |
| `man/man1/` | `zpwr.1`, `zpwrall.1` |
| `tmux/` | tmux configuration |
| `local/` | per-user state, git ignored |

Two files carry user customization and survive `zpwr update`:

- `~/.zpwr/local/.tokens.sh`, sourced before zsh config and zinit startup
- `~/.zpwr/local/.tokens-post.sh`, sourced after all of it

Extra zinit plugins go in the post file:

```zsh
zinit ice lucid nocompile wait'0a'
zinit load \
hlissner/zsh-autopair
```

## The dispatcher

`env/zpwr.zsh` builds a global associative array, `ZPWR_VERBS`. Each key is a verb; each value is `function=description`:

```zsh
ZPWR_VERBS[doctor]='zpwrDoctor=run environment health check diagnostic'
ZPWR_VERBS[bench]='zpwrBench=benchmark startup time with percentiles and baseline diff'
```

`zpwr` sources that file with the caller's arguments on every call. `zpwr <tab>` gives grouped menu completion over the same table. `zpwr verbs` lists verbs in arb and runs the ones you pick, and `zpwr verbsedit` puts them on the command line.

Counts from the table at `origin/main`:

```sh
git show origin/main:env/zpwr.zsh | grep -cE '^\s*ZPWR_VERBS\[[^]]+\]='
# 462
git show origin/main:env/zpwr.zsh | perl -ne 'print "$1\n" if /^\s*ZPWR_VERBS\[([^]]+)\]=/' | sort -u | wc -l
# 460
git show origin/main:env/zpwr.zsh | perl -ne "print \"\$1\n\" if /^\s*ZPWR_VERBS\[[^]]+\]='([^=]+)=/" | sort -u | wc -l
# 373
```

That is 460 distinct verb names mapped onto 373 backing functions. Several verbs are aliases of each other; `wizard` and `docs` both run `zpwrWizard`. The README also lists 2000+ aliases and 360+ git aliases.

## Selected verbs

### zpwr doctor

Scans for stale `.zwc` files, zcompdump freshness, duplicate and missing `PATH`/`FPATH` entries, broken symlinks, invalid named directories, missing dependencies, zinit installation, history files and config symlinks. Output is pass/warn/fail per check, then a summary.

### zpwr bench / zpwr startup / zpwr flame

Three views of startup cost:

```sh
zpwr bench 20      # 20 startups; avg, p50, p99, min, max, spread, baseline delta
zpwr startup 50    # one zprof run, top 50 functions, colored by self-percentage
zpwr flame 40      # ASCII flame chart of the top 40 functions by total time
```

`bench` stores its baseline and history in `$ZPWR_LOCAL/zpwr-bench-baseline.txt` and `$ZPWR_LOCAL/zpwr-bench-history.txt`.

### zpwr snapshot / zpwr restore

`zpwr snapshot [name]` writes named directories, aliases, environment variables, history, the directory stack, git repo status, tmux layout and vim sessions to `$ZPWR_LOCAL/snapshots/`. Restore can be partial:

```sh
zpwr restore myproject aliases env
```

Components are `hash`, `aliases`, `env`, `tmux`, `vim`, `history`, `dirs`. History is merged, not overwritten.

### zpwr pathaudit / zpwr lint / zpwr ports

- `pathaudit` checks `PATH`, `FPATH` and `MANPATH` for duplicates, missing directories and world-writable directories.
- `lint` runs `zsh -n` on autoloads and env files and `shellcheck` on `scripts/` and `install/`.
- `ports` lists listening TCP ports with process, PID, user and bind address; `-k PORT` kills the owner.

## Under zshrs

zshrs implements syntax highlighting, autosuggestions, autopair and history substring search in the shell itself, and ships a native powerlevel10k prompt engine. When `$ZSHRS_VERSION` is set, zpwr sets `ZPWR_NATIVE_ZLE=true` and skips the four equivalent zsh plugins so widgets are not wrapped twice. zshrs also adds an `async_precmd` hook that runs after the prompt is drawn. zpwr moves only the hooks named in `ZPWR_PRECMD_ASYNC_HOOKS` there, and the default list is `zpwrPrecmd`.

## Tests, docs, removal

- `zpwr test` runs the zunit suite; `zpwr testall` includes plugin tests. `origin/main` has 149 `tests/*.zsh` files.
- `man zpwr` is the quick reference and `man zpwrall` is the full verb and variable catalog. Add `$ZPWR/man` to `MANPATH` first.
- `zpwr updateall` relinks configs, pulls, updates plugins, regenerates caches and updates dependencies.
- `zpwr uninstall` asks for confirmation, restores backups, unlinks configs and deletes the config directories.
