# herd's JSON contract

`herd status -j` and `herd show -j` are the machine-readable view of everything herd's web page
shows. The page's server (`herd serve`) only ever runs these and passes their JSON on: it never
parses herdr or git output itself, so bash stays the single source of truth. The herdr plugin's
dashboard reads the same `herd status -j` objects.

Fields are only ever added. Existing fields keep their names, types and order, so a caller that
reads by position (the dashboard's old `@tsv` read did) keeps working.

All three commands take `-b <ref>`, the base that `ahead`, `diff` and `log` are measured against
(default `origin/main`; the plugin passes its `HERD_BASE`).

## `herd status -j [-b ref] [-r repo]`

One JSON object per line, one per stream of the repo. A stream is a linked worktree under
`~/git/wt/<repo>/`, where `<repo>` is the name of the main checkout (also when `-r` names one of
its worktrees). No streams prints nothing.

```json
{
  "branch": "feat/a",
  "agent": "feat-a",
  "status": "working",
  "plan": "stage 2/3 running",
  "path": "/home/me/git/wt/proj/feat-a",
  "workspace": "w5",
  "pane_id": "w5:p1",
  "host": "laptop",
  "ahead": 2,
  "dirty": 1,
  "last_commit": { "sha": "4be1a2c", "subject": "fix: keep the next= param", "rel_time": "3 minutes ago" },
  "plan_detail": {
    "status": "running",
    "stages": [
      { "n": 1, "title": "Parse", "state": "done" },
      { "n": 2, "title": "Writer", "state": "current" },
      { "n": 3, "title": "Docs", "state": "todo" }
    ],
    "stopped_reason": null
  }
}
```

| field | type | meaning |
| --- | --- | --- |
| `branch` | string | the worktree's branch (`-` if detached) |
| `agent` | string | the agent name herd gives the branch (`fix/foo` -> `fix-foo`) |
| `status` | string | the agent's `agent_status` from `herdr agent list` (`working`, `blocked`, `idle`, `done`, `unknown`), or `-` with no agent in the worktree |
| `plan` | string | the plan's place as one label (`stage 2/3 running`, `complete`, `planning`), or `""` with no plan |
| `path` | string | the worktree |
| `workspace` | string | its open herdr workspace id, or `-` |
| `pane_id` | string\|null | the agent's herdr pane (`pane_id` in `herdr agent list`), or null with no agent |
| `host` | string | this machine as the Herdr Mobile Relay knows it: `HERD_RELAY_HOST`, else `hostname -s`. herdr's agent list has no host field |
| `ahead` | number\|null | commits on the branch not in the base; null if the base is unknown or the worktree is gone |
| `dirty` | number\|null | uncommitted files, untracked ones included (`git status --porcelain` lines); null if the worktree is gone |
| `last_commit` | object\|null | `{sha (short), subject, rel_time ("3 minutes ago")}` of HEAD |
| `plan_detail` | object\|null | the plan run, from `.herd/run/`; null when the stream has no plan run (no `.herd/run/state`) |

An agent counts as the stream's when its `cwd` is the worktree or a directory under it.

`plan` was already a string label before `plan_detail` existed, and stays one so existing callers
don't break; the structured plan is `plan_detail`:

| field | type | meaning |
| --- | --- | --- |
| `status` | string\|null | the plan's status from `.herd/run/state`: `planning`, `replanning`, `pending`, `running`, `fixing`, `verified`, `blocked`, `failed`, `complete` |
| `stages` | array | one `{n, title, state}` per `## Stage N: title` in `.herd/run/stages.md`; empty while the planner is still writing them |
| `stages[].state` | string | `done`, `current`, `stopped` or `todo` (below) |
| `stopped_reason` | string\|null | why the plan is stopped: the text after a `STOPPED:` line in `PROGRESS.md`, else a sentence starting `blocked:` or `failed:`; null while it isn't stopped |

A stage is `done` if it comes before the current one, or is the current one and `verified`, or
the plan is `complete`. The current stage is `stopped` if the plan is `blocked` or `failed` or
`PROGRESS.md` has a `STOPPED:` line, and `current` otherwise. Later stages are `todo`.

## `herd status -j -a [-b ref]`

Every repo with streams, as one JSON document. It looks at every directory `~/git/wt/*/*`, maps
each git worktree there back to its main checkout (`git rev-parse --git-common-dir`), and lists
each checkout's streams as `herd status -j` would. Directories that aren't worktrees are skipped,
and so are checkouts with no streams. Runs from anywhere; `-r` is ignored.

```json
{
  "generated_at": "2026-11-09T21:26:24Z",
  "host": "laptop",
  "repos": [
    { "repo": "proj", "path": "/home/me/git/proj", "streams": [ { "branch": "feat/b", "status": "blocked", "...": "..." } ] }
  ]
}
```

| field | type | meaning |
| --- | --- | --- |
| `generated_at` | string | UTC, `YYYY-MM-DDTHH:MM:SSZ` |
| `host` | string | as in a stream |
| `repos` | array | sorted by path; `[]` when there are no streams anywhere |
| `repos[].repo` | string | the main checkout's directory name |
| `repos[].path` | string | the main checkout |
| `repos[].streams` | array | `herd status -j` objects, blocked ones first, otherwise in herdr's worktree order |

Without `-j`, `-a` prints each repo's `herd status` table under a `== repo (path)` line.

## `herd show -j [-b ref] <repo-path> <branch> <what>`

One stream's text. `<repo-path>` is the main checkout or any of its worktrees; `<branch>` must be
one of its streams (as `herd status` lists them), or `herd show` exits 1 with `herd: <branch> is
not a herd stream of <repo>` on stderr. A bad `<what>`, repo or argument count also exits non-zero
with a message on stderr, and prints no JSON.

| `<what>` | text |
| --- | --- |
| `diff` | `git diff <base>` in the worktree: committed and uncommitted changes to tracked files (untracked files are not in it; `dirty` counts them) |
| `log` | `git log --oneline <base>..HEAD` |
| `progress` | `.herd/run/PROGRESS.md`, or `""` without one |
| `screen` | `herdr agent read <pane_id> --source recent-unwrapped --lines 200` of the stream's agent, or `""` with no agent |

```json
{ "text": "diff --git a/x b/x\n...", "truncated": false }
```

`text` stops at 200 KB (204800 bytes); `truncated` is true when it was cut. A cut can land inside
a multi-byte character, which then shows as U+FFFD. Without `-j`, `herd show` prints the (capped)
text itself.
