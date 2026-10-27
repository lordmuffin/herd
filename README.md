# herd

Fan out coding agents into fresh git worktrees, one [Herdr](https://herdr.dev) workspace each,
then clean them up once their PRs merge.

```bash
herd fix/foo "Fix X. Run make test, open a PR labelled review-me."   # one task
herd -f tasks.txt                                                    # a batch, "branch: prompt" per line
herd ls                                                              # agents and their status
herd done fix/foo                                                    # after merge: remove worktree + branches
herd rm fix/foo                                                      # discard a stream (no checks)
```

`herd -h` lists every option. `examples/tasks.example.txt` shows the three useful task shapes:
plan-only, investigate-only, and fix-to-PR.

## What it does

For each task, `herd`:

1. Fetches `origin/main` and creates a branch and a worktree at `~/git/wt/<repo>/<agent-name>`.
2. Opens the worktree as a Herdr workspace, nested under the workspace labelled like the repo
   (`-p <workspace-id>` overrides this).
3. Starts the agent (`claude` by default, `-k` for another kind) and waits until it has begun the prompt.

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
- for `herd done`, a Forgejo login via [forgejo-cli](https://codeberg.org/forgejo-contrib/forgejo-cli)
  (`fj auth login`). The token is read from `~/.local/share/forgejo-cli/keys.json` at runtime.

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

## Develop

`make test` runs `bash -n` and `shellcheck -S warning`, the same checks `makepkg` runs.
