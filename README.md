# herd

Fan out coding agents into fresh git worktrees, one [Herdr](https://herdr.dev) workspace each,
then clean them up once their PRs merge.

```bash
herd fix/foo "Fix X. Run make test, open a PR labelled review-me."   # one task
herd -f tasks.txt                                                    # a batch, "branch: prompt" per line
herd ls                                                              # agents and their status
herd -P forge fix/foo "..."                                          # run the agent as a persona (herd personas lists them)
herd fix/foo@grayfield "..."                                         # persona for one task; also works as "fix/foo@grayfield: ..." in a task file
herd done fix/foo                                                    # after merge: remove worktree + branches
herd done -f tasks.txt                                               # close a whole batch with the same file
herd rm fix/foo                                                      # discard a stream (no checks)
herd rm -f tasks.txt                                                 # discard a whole batch
```

Personas are markdown files in `$HERD_PERSONAS` (default `~/git/Notes/80 Personas`), matched by a case-insensitive part of the file name and passed to claude as `--append-system-prompt-file`. Claude agents on this machine only.

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

Both `done` and `rm` accept `-f <file>` (or `-f -` for stdin). It takes the same task file used to
start the batch; only the branch before the first `:` is read, so the prompts are ignored. Streams
that aren't ready are skipped with a reason, and the rest are still cleaned up, so rerun
`herd done -f tasks.txt` as PRs merge.

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

**macOS** (no package; a checkout plus `make link`):

```bash
brew install jq forgejo-cli       # git, curl, bash 3.2 and column ship with macOS
git clone ssh://git@git-ssh.apj.dev/lordmuffin/herd.git ~/git/herd && cd ~/git/herd
make link                         # ~/.local/bin/herd -> this checkout; update with git pull
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile   # if ~/.local/bin isn't on PATH yet
fj auth login                     # only needed for herd done
```

Install [herdr](https://herdr.dev) as well, and run `herd` from inside a Herdr pane.

- **bash:** `herd` runs on macOS's stock bash 3.2 and doesn't need Homebrew bash.
- **`fj` token store:** on macOS it lives under `~/Library/Application Support/`, and `herd`
  finds it there. If yours is elsewhere, set `FJ_KEYS=/path/to/keys.json`.

## Develop

`make test` runs `bash -n` and `shellcheck -S warning`, the same checks `makepkg` runs.
