# herd

Fan out coding agents into fresh git worktrees, one [Herdr](https://herdr.dev) workspace each,
then clean them up once their PRs merge.

```bash
herd -P engineer fix/foo "Fix X. Label the PR review-me."   # one task, with a persona
herd                                                       # a batch from Tasks.herd in the repo root
herd -f other.herd                                         # a batch from any other file
herd draft "Add CSV export and document it"                # write Tasks.herd from a goal
herd -n                                                    # dry run: what would start, and as what
herd ls                                                    # agents and their status
herd status                                                # this repo's streams, with plan stages
herd status -j -a                                          # every repo's streams, as JSON (docs/serve-api.md)
herd show -j . fix/foo diff                                # one stream's diff|log|progress|screen, as JSON
herd serve                                                 # the streams as a web page for your phone
herd serve pair                                            # the link (and QR code) to pair the phone
herd done fix/foo                                          # after merge: remove worktree + branches
herd done                                                  # close the whole Tasks.herd batch
herd rm fix/foo                                            # discard a stream (no checks)
herd rm -f Tasks.herd                                      # discard a whole batch
herd plan feat/big PLAN.md                                 # one plan, run stage by stage to one PR
herd plan -R feat/big                                      # resume a plan that stopped
```

`herd -h` lists every option. `examples/Tasks.example.herd` shows the useful task shapes:
plan-only, investigate-only, fix-to-PR, docs-only and review-only.

Everything above also works from inside herdr, without the `herd` command: see
[herdr plugin](#herdr-plugin), the recommended way to install herd.

## herdr plugin

herd is a [herdr plugin](https://herdr.dev/docs/plugins/). Install it into herdr, and herdr runs
herd for you: `herd` doesn't need to be on `PATH`, and you don't need a pane to run it from.

```bash
herdr plugin install lordmuffin/herd      # from GitHub; add --ref vX.Y.Z to pin a release
herdr plugin link /path/to/herd           # or a local checkout (make plugin-link)
```

herdr 0.9.5 has no command palette for plugin actions, so bind a key to herd's menu in
`~/.config/herdr/config.toml`, then run `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+h"
type = "plugin_action"
command = "lordmuffin.herd.menu"
description = "herd"
```

Every action works on the repo of the focused pane. From one of herd's worktrees, that is the
main checkout. Each action can also have its own key (`command = "lordmuffin.herd.<id>"`), or you
can run it from a shell with `herdr plugin action invoke lordmuffin.herd.<id>`:

| action | what it does |
| --- | --- |
| `menu` | a picker for every action below |
| `dashboard` | a live, full-screen view of the repo's streams, with actions; see below |
| `fanout` | picks `Tasks.herd` or another `*.herd` file in the repo root, asks for a default persona, shows the dry run, and starts the agents once you say yes |
| `draft` | asks for a goal (one line, or typed in `$EDITOR`) and an output file, runs `herd draft`, then offers to fan the result out |
| `plan` | asks for a branch, a plan (a `*.md` in the repo root, or typed in `$EDITOR`), a default `verify:` command and the stage persona, then runs `herd plan` in a tab of its own |
| `plan-resume` | lists plans that stopped (on a block, a failed gate or a closed tab) and resumes the one you pick |
| `status` | the repo's streams: branch, agent, agent status, plan stage. Refreshes every 10 s |
| `done` | pick streams and run `herd done` on them; the merge checks are unchanged |
| `rm` | pick streams and discard them with no checks, after you type `discard` |
| `serve` | runs `herd serve` in a tab, with the link to pair a phone at the top; it stops when the tab closes. See [Web page and phone](#web-page-and-phone) |
| `personas` | lists personas and shows the prompt each one adds |
| `settings` | opens `herd.conf` in `$EDITOR` |
| `version` | shows the herd version as a notification |

Most actions open as an overlay on the focused pane and close when you're done. A plan gets a
tab, because its driver runs as long as the plan does. If you close that tab, the plan stops
where it is; `plan-resume` picks it up. Pickers use `fzf` when it is installed, and numbers when
it isn't.

**The dashboard.** `dashboard` opens a tab in the repo's own workspace, also when you press its
key in one of the streams. Pressing it again goes back to the open one. Give it a key of its own:

```toml
[[keys.command]]
key = "prefix+H"
type = "plugin_action"
command = "lordmuffin.herd.dashboard"
description = "herd dashboard"
```

```text
herd  ~/git/shop   3 stream(s): 1 blocked · 1 working · 1 idle                      14:02:11
------------------------------------------------------------------------------------------
  BRANCH                             STATUS    PLAN                   WORKSPACE
  feat/export-csv                    working   stage 2/3 running      w5
> fix/login-redirect                 blocked   -                      w6
  docs/api                           idle      -                      w7

fix/login-redirect   agent fix-login-redirect (blocked)   ~/git/wt/shop/fix-login-redirect
git
  2 commit(s) ahead of origin/main · 1 uncommitted file(s)
  last: 4be1a2c fix: keep the next= param through login (3 minutes ago)
agent screen (s for more)
  Do you want to make this edit to src/auth/redirect.ts?
  > 1. Yes
    2. Yes, and don't ask again this session
    3. No, and tell Claude what to do differently
enter go  d done  x discard  r resume  f fan out  n draft  p plan  v diff  s screen  ? keys  q quit
```

The list shows each stream's branch, agent status, plan stage and workspace. Below it is the
selected stream: its plan's stages (`✓` done, `▶` current, `!` stopped there, `·` to come), how
far it is ahead of `HERD_BASE`, uncommitted files, the last lines of `.herd/run/PROGRESS.md`, and
the end of its agent's screen. Keys:

| key | does |
| --- | --- |
| `j` `k`, arrows | select a stream |
| `enter`, `o` | go to the stream: its workspace, else its agent, else reopen its worktree |
| `s` | the agent's screen, in `less` |
| `v` | commits and diff against `HERD_BASE`, in `less` |
| `l` | the plan's `PROGRESS.md`, in `less` |
| `d` | `herd done` on the stream, after a yes; the merge checks are unchanged |
| `x` | discard the stream, after you type `discard` |
| `r` | resume the stream's plan, in a tab of its own |
| `f` `n` `p` | fan out, draft, or start a plan (the same forms as the actions) |
| `g`, `?`, `q` | refresh, keys, close |

To answer a blocked agent, go to it with `enter`; the dashboard doesn't press its keys for you.
The dashboard reloads when the event hook sees one of herd's agents change status or a
worktree come or go, and every 5 seconds anyway (`HERD_DASH_POLL` in `herd.conf`). It is bash and
`jq` like the rest of herd, so there is nothing to build or install.

**Settings.** `herd.conf` lives in `herdr plugin config-dir lordmuffin.herd`. The `settings`
action creates it with every option commented out:

| setting | default | |
| --- | --- | --- |
| `HERD_KIND` | `claude` | agent kind (`-k`) |
| `HERD_BASE` | `origin/main` | base ref (`-b`) |
| `HERD_PERSONA` | none | persona for task lines without `@persona`, and the plan default |
| `HERD_AGENT_ARGS` | none | args for every agent (`-- <args>`), e.g. `"--permission-mode auto"` so a plan runs unattended |
| `HERD_DRAFT_ARGS` | none | args for `draft`'s headless claude |
| `HERD_NOTIFY` | `batch` | `batch`, `all` or `off`; see below |
| `HERD_SIDEBAR` | `1` | report the `$herd` sidebar token |
| `HERD_DASH_POLL` | `5` | seconds between the dashboard's reloads when no event comes sooner |

**Notifications and the sidebar.** herd hooks `pane.agent_status_changed`, but only for agents in
its own worktrees (`~/git/wt/<repo>/...`). With `HERD_NOTIFY=batch`, you get one notification
when every agent of a fan-out has finished, and one when a plan ends or stops. `all` adds one
for each agent that finishes or starts waiting for input. herdr's own toasts for agents in other
tabs (`[ui.toast]`) are separate. herd also reports a `herd` token on its agents' panes: the
branch, or a plan's stage (`stage 2/4 running`). To show it, add `$herd` to a sidebar row:

```toml
[ui.sidebar.agents]
rows = [
  ["state_icon", "machine", "workspace", "tab"],
  ["agent", "$herd"],
]
```

The plugin runs `bin/herd` from its own directory, with the same personas, task files and
`.herd/run/` state, so the plugin and the CLI can be mixed freely. The CLI still has a few things
the plugin doesn't: `-m` remote machines, `-p` parent workspace, and explicit
`branch prompt` pairs on the command line. Event hook and action output is in
`herdr plugin log list --plugin lordmuffin.herd`.

## Tasks.herd

`Tasks.herd` in the repo root is the standard task file, one `branch [@persona]: prompt` per
line. With no tasks on the command line, `herd` and `herd done` read it and print its path;
`-f` or explicit branches take precedence, and with no `Tasks.herd` `herd` prints its usage.
`herd rm` never picks it up on its own, because it deletes without checks: name the file
with `-f`.

## Drafting a task file

`herd draft` turns a goal into a task file, so you don't have to split the work and write the
prompts yourself:

```bash
herd draft "Add CSV export to reports, and document it"   # writes Tasks.herd in the repo root
herd draft -o Tasks-export.herd GOAL.md                    # a file as the goal, another output
herd draft -o - - <GOAL.md                                 # stdin in, stdout out
herd draft "..." -- --model opus                           # extra args for claude
```

A `dispatcher` agent runs headless in the repo root with only `Read`, `Grep` and `Glob`, so it
can read the code but change nothing. It splits the goal into independent tasks, which will run
in parallel from the same base, and writes one `branch @persona: prompt` line for each, with
a comment above it. It picks a persona from the ones `herd personas` lists.

Before saving, herd checks every line the way a run would: the line format, a persona on each
line that resolves, a valid branch that doesn't already exist, and no two tasks with the same
agent name. On a miss, herd sends the dispatcher one fix-up turn in the same session. A second
miss stops the run and leaves the draft in a temp file. The saved file starts with the goal as a
comment, and herd prints its `herd -n` dry run. Read it, edit it if you like, then start it
with `herd`.

An existing output file is refused unless you pass `-F`. Work that has to happen in order is
one task (the dispatcher says so in a comment), and is better run with `herd plan`. `draft`
needs the `claude` CLI and runs on this machine only.

## What it does

For each task, `herd`:

1. Fetches `origin/main` and creates a branch and a worktree at `~/git/wt/<repo>/<agent-name>`.
2. Opens the worktree as a Herdr workspace, nested under the workspace labelled like the repo
   (`-p <workspace-id>` overrides this).
3. Starts the agent (`claude` by default, `-k` for another kind) and sends it the prompt — the
   persona first if one is set, then the task — and waits until it has begun.

## Plans

`herd plan` takes one complete plan and runs it as a chain of stages that build on each
other, in one worktree, on one branch, ending in one PR:

```bash
herd plan feat/export-csv PLAN.md          # a file
herd plan -v "make test" feat/x - <PLAN.md # stdin, with a default verify command
herd plan -n feat/x PLAN.md                # stop once the stages are written, to review them
herd plan -R feat/x                        # resume after a block, a failed gate, or ^C
herd plan -W 120 feat/lab PLAN.md          # wait up to 2 h for a stage's background jobs
```

1. **Planning.** A `planner` turn reads the plan and the code and writes
   `.herd/run/stages.md`: `## Stage N: title` sections, each with a `verify:` command and a
   self-contained prompt. If the plan already has those headings, herd uses it as is and skips
   this turn (`examples/plan.example.md` shows the format).
2. **Stages.** Each stage starts a fresh agent session (`/clear` for claude, `/new` for
   codex), so a long plan never runs on a compacted context. The agent gets the stage prompt,
   with the `-P` persona (default `engineer`), and is told to read `.herd/run/PROGRESS.md`,
   commit its work and append a `## Stage N` handoff section to it.
3. **Gate.** When the turn ends, herd checks the handoff section exists, the tree is clean,
   and the stage's `verify:` command (or `-v`) passes. If the gate fails, herd sends one
   fix-up turn with the failures. If it fails a second time, herd stops. The last stage must
   also push and open the PR, and herd checks that the PR exists: with `gh` for a github.com origin,
   with a forgejo-cli login for any other host. Where it can't check, it says so and skips that check.
   An idle agent that is still waiting on work it started is not done: before gating, herd
   reads the pane, and while claude's footer shows background work (`1 shell, 1 monitor still
   running`, or `· 2 shells ·` in its status line) herd re-checks every 30 s instead of gating
   (`HERD_BG_POLL` sets the interval). When the job finishes, the agent wakes, finishes the
   stage, and herd gates that turn. A fix-up turn that ends on background work is waited out
   the same way, so it doesn't count as the second failure. Every stage prompt also tells the
   agent never to end a turn while a job, Monitor or eval it started is still running, which
   covers agents whose footer herd can't parse.
4. **Stops.** A blocked agent, or a stage that fails twice, stops the run with the reason;
   fix it in the pane (or edit `stages.md`), then `herd plan -R <branch>`. The step state is in
   `.herd/run/state`, so `-R` re-checks the stage where it stopped and carries on. Two more
   stops don't count as a failed gate:
   - **Background work past the cap.** herd waits at most 60 minutes for it (`-W <min>` to
     change, also on `-R`), then stops with that reason.
   - **`STOPPED:`.** A line starting `STOPPED:` in `.herd/run/PROGRESS.md` stops the run as
     soon as the turn ends, with that line as the reason and no fix-up turn. Use it for a
     plan's own stop rules ("if the lab host is unreachable, write `STOPPED: <why>`") instead of
     adding `! grep -q '^STOPPED' .herd/run/PROGRESS.md` to every `verify:`. Delete the line
     before `-R`.

`.herd/run/` is added to the repo's `info/exclude`, so the plan, stages and handoff notes never
land in the PR. `herd done <branch>` cleans up as usual once it merges. `verify:` commands run
unattended in the worktree, outside the agent's permission prompts. The planner writes them,
so read them with `-n` when that matters. `herd plan` runs on this machine only (no `-m`).

**Running unattended.** A plan only runs on its own if its agent doesn't stop to ask
permission. Under Claude's default mode, the first shell command that isn't on its allowlist
blocks the stage, and herd stops there and waits for `-R`. Pass the agent a permission mode
after `--`:

```bash
herd plan feat/x PLAN.md -- --permission-mode auto   # Claude's classifier answers the prompts
```

`--permission-mode acceptEdits` with `--allowedTools` works too, but the allowlist has to cover
every command a stage might run, compound ones included. A narrow list still blocks. Avoid
`bypassPermissions` outside a throwaway repo. Before the first run in a new repo, open Claude
there once and accept its folder trust prompt: an agent still sitting at that prompt fails to
start, and herd stops before stage 1.

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

Seven ship with `herd`, each self-contained and agent-agnostic:

| persona | leaves behind | touches code |
| --- | --- | --- |
| `engineer` | a tested, scoped change and a PR | yes |
| `architect` | `PLAN.md`, then stops for review | no |
| `researcher` | `FINDINGS.md`, with file:line anchors | no |
| `reviewer` | `REVIEW.md`, findings ranked by consequence | no |
| `writer` | docs edits and a PR | docs only |
| `planner` | `.herd/run/stages.md` for `herd plan` | no |
| `dispatcher` | a task file, for `herd draft` | no |

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

## Web page and phone

`herd serve` serves herd's streams as a small web page and JSON API, made for a phone: which
stream is blocked, working or idle, each plan's stages, a stream's diff, log, progress and agent
screen, and a **New** sheet to start work. It needs Python 3 (the standard library only); nothing
else in herd does.

**Two ways to prompt from the phone, on purpose.** Answering an agent (a permission prompt, a
question) happens in Herdr Mobile, through the herdr relay: it is a live terminal, and it already
knows how to talk to a pane. Every blocked card on the page has an **Open in Herdr Mobile** button
that deep-links to that pane. Starting and closing *herd* work (a task, a draft and its fan-out, a
plan, done, discard) goes through `herd serve`, because it runs `herd` on the computer, with the
same checks as the CLI. herd serve never types into an agent's pane, and the relay never starts a
herd stream.

**On this computer first.** Run it, and open the link `herd serve pair` prints:

```bash
herd serve                  # 127.0.0.1:8380, until ^C (or run the plugin's serve action: a tab)
herd serve pair             # the page's link, with this device's token in it
```

The first start on loopback writes two tokens to `~/.local/state/herd/serve-tokens.json` (mode
0600). The plugin's `serve` action does both in a herdr tab and stops the server when the tab
closes.

**Over NetBird.** Listen on the computer's NetBird address and name the hostnames the phone uses,
in herd.conf (the plugin's Settings action opens it):

```bash
HERD_SERVE_LISTEN=100.64.12.34              # this computer's NetBird IP
HERD_SERVE_HOSTS="lap.netbird.cloud"        # other names the page is opened by (Host check)
#HERD_SERVE_PORT=8380
#HERD_SERVE_REPOS="$HOME/git/herd"          # repos to start streams in that have none yet
```

A non-loopback address is only used with `--listen` on the command line and once the tokens
exist, so a stray herd.conf line can't open the server up: run `herd serve` once on loopback,
then `herd serve --listen 100.64.12.34`. `herd serve install` does that for you: it writes a
systemd user unit (`~/.config/systemd/user/herd-serve.service`, `Restart=on-failure`) on Linux or
a launchd agent (`~/Library/LaunchAgents/lordmuffin.herd-serve.plist`) on macOS, with the flags
from herd.conf, and starts it. Run it again after changing herd.conf; `herd serve uninstall`
removes it. It never touches system-wide units. A systemd user unit stops when you log out
unless lingering is on (`loginctl enable-linger`).

**Pairing an Android phone.** Run `herd serve pair` on the computer. It prints a link per
address, `http://<address>:<port>/#t=<token>`, and a QR code for each when `qrencode` is
installed. Scan it (or open the link) on the phone, in Chrome. The page keeps the token and drops
it from the address bar. Then Chrome's menu, **Add to Home screen** (or **Install app**), gives
herd an icon and a full-screen window. `herd serve pair --reader` pairs a look-only device.

**Answering from the phone.** Set `HERD_RELAY_APP_URL` in herd.conf to the Herdr Mobile app's
URL (the address you open the relay app at). Without it the page shows no Open in Herdr Mobile
button. `HERD_RELAY_HOST` sets this computer's name in the relay, if it isn't `hostname -s`.

**Security model.**

- Two tokens: a **reader** can look; the **controller** can also start, fan out, plan, finish
  and discard streams. Every API call sends one as `Authorization: Bearer`; there are no cookies,
  so another site can't make your browser act for you. `herd serve revoke [--reader|--controller]`
  makes a new token, which signs out every device that had the old one, at once.
- A request whose `Host` isn't the listen address, `localhost` or a `HERD_SERVE_HOSTS` name is
  refused, which stops DNS rebinding. Listen on loopback or a private network (NetBird) only; the
  server speaks plain HTTP.
- Every write lands in `~/.local/state/herd/serve-audit.jsonl`: time, token role, route, repo,
  branch and result. A prompt, goal or plan is kept only as its length and sha256.
- Writes run `herd` with an argument list, never a shell, and check what they get: known repos
  only, branch names as `herd draft` checks them, task files in the repo root only, a fan-out
  only with the hash of its current preview, discard only with `discard` typed.
- `herd serve --read-only` (or `HERD_SERVE_READ_ONLY=1`) turns every write off.

The routes and their answers are in [docs/serve-api.md](docs/serve-api.md).

## Herdr desktop app

herd also drives the [Herdr desktop app](https://herdr.dev) (`herdr-app`), whose terminals and
agents run in herdr-core (`hc`). Every command above works there, and a `herd` mod adds a panel
for it.

**Which herdr.** herd picks the herdr to drive from the terminal it runs in:

- a Herdr app terminal (one with `HC_TERMINAL_ID`) means the app;
- a terminal-herdr pane or plugin means the terminal herdr;
- anywhere else means the terminal herdr, as before.

`HERD_BACKEND=desktop` or `HERD_BACKEND=tui` overrides this, and `herd backend` prints the
choice.

**What herd does in the app.** Each stream gets a space of its own:

- herd runs `git worktree add`, then starts a kept shell in the checkout with `hc run`. The
  shell's `herdr.space`/`herdr.tab` labels make the app show it as a new space, without taking
  focus. Its other labels are `herd=1`, `herd.path` and `herd.branch`.
- The agent is typed into that shell. The terminal is named after the agent, so
  `hc read <agent>` and `hc send <agent> ...` work.
- Prompts, waits, status and screen reads go through `hc send`, `wait`, `get` and `read`. That
  covers `herd plan`'s gates and its check for background work too.
- `herd rm` and `herd done` close the space and remove the worktree.

Worktrees stay in herd's `~/git/wt/<repo>/<branch>`, so a stream started from the terminal herdr,
the plugin or the app is the same stream to `herd status` and `herd done`. The app's spaces
sidebar still nests these spaces under their repo, because it goes by git's common dir and not
by path. Its *Open worktree* lists them too.

If a new agent asks whether to trust its folder, herd waits up to 10 minutes for you to answer it
in the agent's space (`HERD_ASK_WAIT` sets the seconds), then sends the task. The app has no
equivalent of `-m` (other machines) or `-p` (parent workspace) yet. `-m` is refused, and `-p` is
ignored.

**The panel.** `desktop/mods/herd` is a mod for the app. It lists the focused repo's streams with
their live agent status and plan stage, and a click on a row goes to that stream's space. Its
buttons:

- **Fan out** picks a `Tasks*.herd`, shows the dry run in the app's confirm dialog, then starts
  the agents.
- **Plan…** asks for a branch and a plan, and runs `herd plan` in a new tab, where its log stays
  visible.
- **Draft…** asks for a goal and writes a task file, then offers to fan it out.
- **Done** on a row runs `herd done`, after a confirm.

Results come back as toasts. A click on one shows the whole output. Install the mod from a
checkout:

```bash
make desktop-install     # copies desktop/mods/herd to ~/.config/herdr-app/mods/herd, bundles this
                         # checkout's bin/herd + personas in it, and runs herdr-app check
```

Then add the panel to your layout: a clone of `main`, since shipped layouts are read-only. Put it
after the `panel` column in `work-body`:

```json
{ "id": "herd-panel", "type": "column", "size": { "px": 300 }, "min": 240, "max": 560,
  "children": [{ "id": "herd", "type": "block", "content": { "mod": "herd" } }] }
```

`desktop/keys.json` has optional keys to merge into `~/.config/herdr-app/keys.json`: `ctrl-shift-h`
toggles the panel, and `ctrl-alt-f`, `ctrl-alt-p` and `ctrl-alt-d` start a fan-out, a plan or a
draft. `desktop/RECIPE.md` describes the mod in full, for rebuilding or sharing it.

## Requirements

- [herdr](https://herdr.dev). The plugin needs herdr 0.9.5 or newer. The CLI runs from inside a
  Herdr pane;
- `bash` 4 or newer, `git`, `jq` and `curl` (`fzf` is optional, for the plugin's pickers);
- `column` (from util-linux);
- for `herd serve` only: Python 3 (`qrencode` is optional, for `herd serve pair`'s QR code);
- for `herd done` and the PR check in `herd plan`: `gh` (logged in) for repos on github.com, and for
  any other host a Forgejo login via [forgejo-cli](https://codeberg.org/forgejo-contrib/forgejo-cli).
  `fj auth login` needs an OAuth app registered on the instance; where there isn't one, create a
  token at `/user/settings/applications` (`read:repository` covers `herd done`; `write:repository`
  if the agents open their PRs with `fj` too) and add it with
  `fj auth add-token` (`add-token` refuses to overwrite, so `fj auth logout <host>` first to
  replace a dead one). The token is read from forgejo-cli's `keys.json` at runtime — the XDG
  data dir on Linux, `Application Support` on macOS.

## Install

herd is developed on a private Forgejo and mirrored to
[github.com/lordmuffin/herd](https://github.com/lordmuffin/herd); everything below uses the
public GitHub copy. `herd --version` (or the plugin's `version` action) tells you what you have.

**herdr plugin (recommended)**. No `herd` on `PATH` needed. See [herdr plugin](#herdr-plugin):

```bash
herdr plugin install lordmuffin/herd   # herdr plugin update lordmuffin.herd to update
```

Every install below also puts the plugin in `<prefix>/share/herd`. To use the plugin and the
CLI from one install, register that copy instead: `herdr plugin link /usr/share/herd` for a
package, or `herdr plugin link ~/.local/share/herd` after `make install`.

**Release tarball** (any Linux; needs GNU coreutils for `install -D`). Download the tarball and
`SHA256SUMS` from the [latest release](https://github.com/lordmuffin/herd/releases/latest):

```bash
sha256sum -c --ignore-missing SHA256SUMS
tar xzf herd-X.Y.Z.tar.gz && cd herd-X.Y.Z
make install                       # into ~/.local; PREFIX=/usr sudo make install for system-wide
make uninstall                     # same PREFIX to remove
```

**Arch / CachyOS, from the release** (puts `herd` in `/usr/bin`). Each release has a prebuilt
`herd-X.Y.Z-1-any.pkg.tar.zst` (`sudo pacman -U` it) and a `PKGBUILD` with the checksum filled in; or build the
tagged version from `packaging/arch/herd/PKGBUILD` (its checksum is `SKIP`, so prefer the release one):

```bash
git clone https://github.com/lordmuffin/herd.git && cd herd/packaging/arch/herd
makepkg -si
```

**Arch / CachyOS, tracking main** (`herd-git`; rerun to update to the latest main):

```bash
git clone https://github.com/lordmuffin/herd.git && cd herd
makepkg -si
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
git clone https://github.com/lordmuffin/herd.git && cd herd
make link            # git pull to update
```

Homebrew's bash is required: `herd` uses bash 4+ features and macOS ships 3.2 at `/bin/bash`.
Stock `/usr/bin/column` and `curl` are fine. For `herd done`, add `brew install forgejo-cli`;
its token lands in `~/Library/Application Support/forgejo-cli.forgejo-cli/keys.json` (the
doubled name is the `directories` crate's macOS layout), which `herd` checks after the XDG path.

**Windows** — herd is a bash script and needs a Linux userland (`column` and `uuidgen` from
util-linux, GNU `sed`/`install`), so run it under [WSL2](https://learn.microsoft.com/windows/wsl/install)
and keep herdr, git, your agents and your repos all inside the WSL distro. From PowerShell:

```powershell
wsl --install -d Ubuntu      # once; reboot if asked, then open the Ubuntu shell
```

Then, inside Ubuntu:

```bash
sudo apt update && sudo apt install -y git jq curl make util-linux
curl -fsSL https://releases.herdr.dev/app/install.sh | sh   # the Linux herdr, inside WSL
git clone https://github.com/lordmuffin/herd.git && cd herd
make install                 # into ~/.local/bin; or make link for a dev checkout
```

Alternatively, install the release tarball as in **Release tarball** above. Check that
`~/.local/bin` is on `PATH` (Ubuntu's `~/.profile` adds it once the directory exists, so open a
new shell), then start herdr in WSL and run `herd` from one of its panes. herdr's Linux build is a desktop
app, so it opens through WSLg (built into WSL2 on Windows 11 and recent Windows 10). For `herd done`,
install `gh` or forgejo-cli inside WSL, not on Windows.

Keep repos on the Linux filesystem (`~/src/...`), not under `/mnt/c`. Git and worktrees are
much slower across the Windows mount, and Windows-side git can rewrite line endings.

herdr also ships a native Windows build (`irm https://releases.herdr.dev/app/install.ps1 | iex`),
but herd isn't tested with it. herd has to run in a bash pane that can call `herdr`, and
neither Git Bash nor MSYS2 provides `column`/`uuidgen` from util-linux out of the box. Use
WSL2 unless you want to experiment.

## Develop

`make test` runs `bash -n`, `shellcheck -S warning` and `tests/plan.sh` (the `herd plan` stage
loop against a faked herdr), the same checks `makepkg` runs. `tests/plugin.sh` checks
`herdr-plugin.toml` against herdr's manifest rules (with `python3`'s `tomllib` where available)
and drives every plugin action, pane and the event hook against a fake herdr.

The plugin is `herdr-plugin.toml` and `plugin/herd-plugin.sh`, which calls `bin/herd`.
`make plugin-link` registers this checkout with herdr (edits are live), and `make plugin-unlink`
removes it again.

## Publishing (maintainer notes)

The canonical repo is the private Forgejo; GitHub is a read-only mirror. Both run
`.github/workflows/ci.yml`, which runs `make test` on every push and pull request.

- **Forgejo cuts the release.** After the tests pass on a push to main, it reads `VERSION`. If
  there is no `vX.Y.Z` release yet, it creates one at that commit, which also creates the tag.
  The release gets the source tarball, `SHA256SUMS`, a `PKGBUILD` with the checksum filled in,
  and the Arch package if the runner has docker (`packaging/release-assets.sh` builds them all).
  Merges that leave `VERSION` alone ship nothing.
- **GitHub mirrors it.** When the push mirror carries the tag over, GitHub builds the same
  assets and publishes a matching GitHub Release. GitHub never creates tags itself, because the
  push mirror would delete a GitHub-only tag again.

One-time setup:

1. Create an empty `lordmuffin/herd` repo on GitHub (no README or license; Forgejo pushes those).
2. Sync Forgejo to it, either way:
   - **Push mirror (automatic).** In Forgejo: repo, Settings, Repository, Mirror settings, "Push
     mirror". Git remote URL `https://github.com/lordmuffin/herd.git`, username `lordmuffin`,
     password a GitHub fine-grained personal access token limited to that repo with
     Contents: read and write. Enable "Sync when commits are pushed". Tags are mirrored too.
   - **Manual.** `git remote add github git@github.com:lordmuffin/herd.git`, then
     `make sync-github` pushes `main` and all tags.
3. Releasing: bump `VERSION` in the PR (or in a commit on main) and merge. Forgejo publishes
   `v<VERSION>`; GitHub follows when the mirror next syncs. A tag created through the API may
   wait for the mirror's interval, so press "Synchronize now" in the mirror settings to hurry it.
   The release uses Forgejo's automatic Actions token. If your instance doesn't let that token
   create releases, add a `FORGEJO_RELEASE_TOKEN` secret (a token with `write:repository`).
   `packaging/release-assets.sh` builds the same files locally into `dist/`.
4. For the AUR, copy the release's `PKGBUILD` into an AUR `herd` repo and run
   `makepkg --printsrcinfo > .SRCINFO`.
5. For the [herdr plugin marketplace](https://herdr.dev/plugins/), add the `herdr-plugin` topic to
   the GitHub repo; its index finds `herdr-plugin.toml` at the root. Keep the manifest's
   `version` equal to `VERSION` (`make test` checks this).
