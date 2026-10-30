---
title: zsh-more-completions, Layout, Install and How Completions Get In
date: 2026-10-30
tags: [zsh-more-completions, zsh, completion, compsys]
summary: How the zsh-more-completions corpus is split across directories, how its plugin file wires them into fpath, and how new completion files are harvested and checked.
---
[zsh-more-completions](https://github.com/MenkeTechnologies/zsh-more-completions) is a zsh plugin made of `#compdef` completion files for compsys. The README says most files were first generated from `--help` output, man pages and web research, then cleaned and updated by hand, and that many were written by hand from the start.

The README also treats the corpus as reference material. Each `_command` file uses the same schema: a `#compdef` header, then `_arguments` / `_describe` blocks that list subcommands, flags and arguments with descriptions. You can read a command's options from its file without installing the command.

## Size

All counts below come from `origin/main` at `c66e5683dd`. The repo has a stats script, `scripts/print-repo-stats.zsh`, that counts `_*` files with `find -maxdepth 1 -type f` in each completion directory. This tree query counts the same files without a checkout:

```sh
git ls-tree -r --name-only origin/main \
  | perl -ne 'print "$1\n" if m{^([^/]+)/_[^/]*$}' | sort | uniq -c
```

| Directory | `_*` files | Purpose (README) |
|---|---|---|
| `src/` | 8,360 | main completions |
| `more_src/` | 13,128 | additional (0-9, a-c) |
| `more_src2/` | 4,497 | additional (d-g) |
| `more_src3/` | 3,788 | additional (h-l) |
| `more_src4/` | 5,244 | additional (m-p) |
| `more_src5/` | 3,717 | additional (q-s) |
| `more_src6/` | 3,973 | additional (t-z) |
| `more_src7/` | 100 | automated generation |
| `more_src8/` | 100 | automated generation |
| `man_src/` | 3,398 | parsed from man pages |
| `override_src/` | 22 | overrides, prepended to `fpath` |
| `architecture_src/` | 1,067 | cross-architecture toolchains |
| **total** | **47,394** | |

The README headline says 47,398. It also says counts change constantly and should never be edited by hand, and points to the stats script for live numbers.

`architecture_src/` holds target-prefixed toolchain binaries such as `_aarch64-alpine-linux-musl-gcc`. `override_src/` is a short list (`_git`, `_curl`, `_whois`, `_ztmux`, `_zshrs` and others) meant to win over completions found elsewhere on `fpath`.

## How the plugin loads

`zsh-more-completions.plugin.zsh` is 18 lines. It does not autoload anything and does not call `compinit`. It only edits `fpath`:

```zsh
local __zsh_more_comp_dirs_first=("$1/override_src")
local __zsh_more_comp_dirs_last=("$1/src" "$1/more_src" ... "$1/man_src" "$1/architecture_src")
```

`override_src` is prepended. Every other directory is appended, after the system completion directories, so a completion shipped with zsh or the OS still wins over the plugin's copy. Each directory is added only if it is not already on `fpath`.

## Installing

### Zinit (README: recommended)

```zsh
source "$HOME/.zinit/bin/zinit.zsh"
zinit ice lucid nocompile wait'0e' nocompletions
zinit load MenkeTechnologies/zsh-more-completions
```

`nocompletions` stops zinit from symlinking every file into `~/.zinit/completions`. The plugin's own `fpath` ordering then applies, so `override_src` stays first and system completions stay ahead of the rest.

### Oh My Zsh

```sh
cd "$HOME/.oh-my-zsh/custom/plugins" && git clone https://github.com/MenkeTechnologies/zsh-more-completions.git
```

Add `zsh-more-completions` to `plugins`. OMZ adds only the plugin root to `fpath`, so the README gives a loop to run before OMZ calls `compinit`. It adds each `*src` directory, putting `override` directories first:

```zsh
for plug in ${plugins[@]}; do
    if [[ -d "$ZSH/custom/plugins/$plug" ]]; then
        for dir in "$ZSH/custom/plugins/$plug/"*src(N); do
            if [[ -d "$dir" ]]; then
                if [[ -z ${fpath[(r)$dir]} ]];then
                    if [[ $dir = *override* ]]; then
                        fpath=($dir $fpath)
                    else
                        fpath=($fpath $dir)
                    fi
                fi
            fi
        done
    fi
done
```

A comment in the plugin file says that under OMZ, `compinit` has to run twice: once in OMZ, and once after the plugin file is sourced.

### Manual

Clone the repo and copy the `_*` files from the source directories to a directory on your `fpath`.

### Then

```zsh
autoload -Uz compinit && compinit
```

The README suggests `compinit -C` for faster startup. It skips the security check and loads the cached `~/.zcompdump`.

## How completions are added

The `scripts/` directory holds the harvesters:

- `harvest-apt-completions.py`
- `harvest-brew-completions.py`
- `harvest-crates-completions.py`
- `harvest-gh-releases.py`
- `harvest-nix-completions.py`
- `harvest-web-completions.py`

The Homebrew harvester's docstring gives the pipeline for each formula:

1. Skip if `_<formula>` is already in `src/` or `more_src/`, or is in `blacklist.txt`.
2. Run `brew fetch --quiet <formula>` to pull the bottle without installing it.
3. Stream-extract `share/zsh/site-functions/_*` from the tarball.
4. Dedup, validate with `zsh -nf`, write headers and body to `more_src/_<stem>`, and add the stem to the blacklist.

`blacklist.txt` (51,623 lines at this commit) is the dedup ledger. Once a command name is covered, harvesters skip it. The APT harvester loads and merges the same file.

The README's harvest list goes past package managers: Nix, Homebrew, APT, Fedora, Alpine, FreeBSD, Kali, crates.io, npm, and source-level work on scientific and infrastructure toolkits. For many of those, it says flag tables were read from each tool's `usage()` function, argparse setup or man page source.

Hand-written files follow the same rules. The files in `override_src/` show the format, for example `_whois`:

```zsh
#compdef whois fwhois
# Documentation: https://man.archlinux.org/search?q=whois
# Reference accessed: 2026-05-16
```

## Tests

```sh
zunit tests/*.zsh
```

GitHub Actions runs the same command on Ubuntu. At this commit, `tests/` has 22 `.zsh` files with 22,642 `@test` entries (`git grep -h '^@test' origin/main -- 'tests/*.zsh' | wc -l`). Among the checks:

- every `override_src` file starts with `#compdef`, and every `src` file starts with `#compdef` or `#autoload` (`t-headers.zsh`)
- conventions such as `_files` for filename arguments, bracketed option descriptions, and combined short and long option specs (`t-conventions.zsh`)
- `blacklist.txt` exists, is non-empty and has no duplicate lines, and the CI workflow contract holds (`t-repo-invariants.zsh`)
