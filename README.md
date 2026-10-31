# herd

Fan out coding agents into fresh git worktrees, one [Herdr](https://herdr.dev) workspace each,
then clean them up once their PRs merge.

```bash
herd -P engineer fix/foo "Fix X. Label the PR review-me."   # one task, with a persona
herd -f tasks.txt                                          # a batch, "branch [@persona]: prompt" per line
herd -n -f tasks.txt                                       # dry run: what would start, and as what
herd ls                                                    # agents and their status
herd done fix/foo                                          # after merge: remove worktree + branches
herd rm fix/foo                                            # discard a stream (no checks)
```

`herd -h` lists every option. `examples/tasks.example.txt` shows the useful task shapes:
plan-only, investigate-only, fix-to-PR, docs-only and review-only.

## What it does

For each task, `herd`:

1. Fetches `origin/main` and creates a branch and a worktree at `~/git/wt/<repo>/<agent-name>`.
2. Opens the worktree as a Herdr workspace, nested under the workspace labelled like the repo
   (`-p <workspace-id>` overrides this).
3. Starts the agent (`claude` by default, `-k` for another kind) and sends it the prompt — the
   persona first if one is set, then the task — and waits until it has begun.

## Personas

A persona is a plain-markdown prompt that says how the agent should work — what it reads first,
what it must not touch, and what it has to leave behind. `herd` prepends it to the task, so the
task only has to say *what*, not *how*:

```bash
herd -P researcher chore/audit "Audit every Flux Kustomization under clusters/k3s2/ for wait: true."
```

```bash
herd personas              # name, one-line summary, and which file won
herd personas engineer     # print the composed prompt (pipe it into any agent, herd or not)
```

Five ship with `herd`, each self-contained and agent-agnostic:

| persona | leaves behind | touches code |
| --- | --- | --- |
| `engineer` | a tested, scoped change and a PR | yes |
| `architect` | `PLAN.md`, then stops for review | no |
| `researcher` | `FINDINGS.md`, with file:line anchors | no |
| `reviewer` | `REVIEW.md`, findings ranked by consequence | no |
| `writer` | docs edits and a PR | docs only |

In a task file, `@persona` on a line overrides `-P`, and `@none` runs the prompt bare:

```
fix/bar @engineer: Fix bar.
chore/audit @researcher: Audit X and report.
raw/thing @none: whatever you like.
```

### Writing your own

Any `.md` file works — there is no schema. The `> ...` line under the title is what
`herd personas` shows as the summary. The search path, most specific first:

1. `$HERD_PERSONA_DIR`
2. `<repo>/.herd/personas/` — commit these to give a repo its own house rules
3. `~/.config/herd/personas/` (`$XDG_CONFIG_HOME` honoured)
4. the ones shipped with `herd`

A name with no exact file falls back to a case-insensitive fuzzy match, so `-P kai` finds
`Kai - The Kaizen Engineer.md`. A match on the whole name or its first word wins over one that merely
contains the text (`kai` is not ambiguous with `Kairos`); anything still ambiguous errors and lists
the candidates. To get short names for files with long ones, symlink them into
`~/.config/herd/personas/` (`ln -s "/path/Forge - The Platform Engineer.md" forge.md`).

`-P` also takes a path, so `-P ./one-off.md` works without installing anything. Every persona
in a run is resolved before any agent starts, so a typo fails the whole run instead of leaving
half a fan-out going.

## Cleanup

`herd done` removes a stream only when all of these hold:

- its PR is merged;
- the branch has no commits missing from main;
- the agent is not working or blocked;
- the worktree is clean.

It then removes the worktree, closes the workspace, and deletes the local and remote branch.
`-F` skips the checks.

## Requirements

- [herdr](https://herdr.dev), run from inside a Herdr pane;
- `bash`, `git`, `jq` and `curl`;
- `column` (from util-linux);
- for `herd done`, a Forgejo login via [forgejo-cli](https://codeberg.org/forgejo-contrib/forgejo-cli).
  `fj auth login` needs an OAuth app registered on the instance; where there isn't one, create a
  token at `/user/settings/applications` (`read:repository` covers `herd done`; `write:repository`
  if the agents open their PRs with `fj` too) and add it with
  `fj auth add-token` (`add-token` refuses to overwrite, so `fj auth logout <host>` first to
  replace a dead one). The token is read from forgejo-cli's `keys.json` at runtime — the XDG
  data dir on Linux, `Application Support` on macOS.

## Install

**CachyOS / Arch, as a package** (puts `herd` in `/usr/bin`, updates through `makepkg`):

```bash
git clone ssh://git@git-ssh.apj.dev/lordmuffin/herd.git && cd herd
makepkg -si          # rerun in this directory to update to the latest main
```

**Dev checkout** (symlinks `~/.local/bin/herd` to this repo, so edits are live):

```bash
make link            # make uninstall to remove
```

Use one of the two per machine. `~/.local/bin` usually comes first in `PATH`, so a symlink
there hides the packaged `/usr/bin/herd`.

**macOS** — `makepkg` is Arch-only, and `make install` needs GNU coreutils (BSD `install` has
no `-D`), so use the dev checkout:

```bash
brew install bash jq shellcheck
git clone ssh://git@git-ssh.apj.dev/lordmuffin/herd.git && cd herd
make link            # git pull to update
```

Homebrew's bash is required: `herd` uses bash 4+ features and macOS ships 3.2 at `/bin/bash`.
Stock `/usr/bin/column` and `curl` are fine. For `herd done`, add `brew install forgejo-cli`;
its token lands in `~/Library/Application Support/forgejo-cli.forgejo-cli/keys.json` (the
doubled name is the `directories` crate's macOS layout), which `herd` checks after the XDG path.

## Develop

`make test` runs `bash -n` and `shellcheck -S warning`, the same checks `makepkg` runs.
