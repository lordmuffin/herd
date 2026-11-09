# A real interface for herd: options and a recommendation

herd is a bash CLI (`bin/herd`) plus a herdr plugin (`herdr-plugin.toml`, `plugin/herd-plugin.sh`).
Today the plugin offers keybinding-launched actions that open terminal panes with fzf or numbered
pickers, a `pane.agent_status_changed` hook, a `$herd` sidebar token, and notifications. This note
compares the realistic ways to give herd a proper interface. It recommends one, which this branch
prototypes as the `dashboard` action.

Facts below were checked against herdr 0.9.5. Sources: the docs
(`docs/versions/0.9.5/website/src/content/docs/{plugins,cli-reference,configuration}.mdx` in
herdrdev/herdr), the source (`src/app/api/plugins/runtime.rs`), the running server
(`herdr api schema --json`, `herdr api snapshot`, `herdr <group>` help), the installed Herdr
Mobile Relay plugin (v0.22.13), and the herdrdev/herdr-app and herdrdev/herdr-core READMEs and
mod guide (`defaults/AGENTS.md`). Anything not checked that way is marked *unverified*.

## What a herd UI has to do

| job | today | what a real UI adds |
| --- | --- | --- |
| overview of all streams and agents, live | `status` pane redraws a table every 10 s | one screen, updated on events, with counts and attention first |
| a plan's stage timeline | `stage 2/4 running` in a column | every stage with done, current and stopped marks, and the progress log |
| approve or unblock a waiting agent | a notification, then find the pane | jump straight to the blocked agent, see its question first |
| launch a fan-out, plan or draft | overlay forms | the same forms, started from the overview |
| review diffs and PRs | leave herdr, run git | the diff against the base in a pager; PR state (later) |
| done and cleanup | multi-select picker | act on the selected stream in place |

## The surfaces herdr 0.9.5 really has

- **Plugin panes are terminals.** "Runtime action registration and native non-terminal plugin
  UI are not part of plugin v1" (plugins.mdx). Placements are `overlay`, `popup` (with `width`
  and `height`, no pane id, closes when its command exits), `split`, `tab` and `zoomed`. Split,
  tab, zoomed and overlay panes are ordinary panes once open, so `pane move`, `pane zoom` and
  the rest work on them.
- **Runtime env.** Every runtime command gets `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`,
  `HERDR_PLUGIN_{ID,ROOT,CONFIG_DIR,STATE_DIR,CONTEXT_JSON}`, and `HERDR_WORKSPACE_ID`,
  `HERDR_TAB_ID` and `HERDR_PANE_ID` when known. Event hooks also get `HERDR_PLUGIN_EVENT` (the
  dotted name, like `worktree.created`) and `HERDR_PLUGIN_EVENT_JSON`.
- **Build.** `[[build]]` runs only on `herdr plugin install` from GitHub, after confirmation. It
  doesn't run on `plugin link`. It gets no socket env, and a failure aborts the install. Herdr
  "does not install missing toolchains".
- **Startup and lifetime.** `[[startup]]` hooks run once per server start. They are "one-shot
  initialization commands rather than supervised daemons", and "plugins must stop detached
  background processes before their parent command or pane exits". So a long-lived server, such
  as a web UI, needs its own supervisor. The mobile relay uses a systemd user unit or a launchd
  agent.
- **Events.** Manifest hooks fire for workspace, worktree, tab and pane lifecycle events and for
  `pane.agent_status_changed`. Over the socket, `events.subscribe` streams events, but the
  `pane.agent_status_changed` subscription *requires a `pane_id`*, so it is per pane, not global.
  `events.wait` waits for one matching event. The CLI has no events command: `herdr api` has only
  `snapshot` (the whole session as JSON, about 46 KB here) and `schema`. Subscribing from a
  script therefore needs a raw socket client (`socat`, `nc -U`, Python, Go), and Windows uses a
  named pipe instead.
- **Metadata.** `pane report-metadata` sets `--token NAME=VALUE`, `--state-label STATUS=TEXT`,
  `--display-agent`, `--title` and `--ttl-ms`. `workspace report-metadata --token` feeds Space
  rows. Sidebar rows can style a token, with rules (`equals`, `contains`, `gt`, `lt`, `hide`).
  Values are capped at 80 characters.
- **Notifications.** `notification show <title> --body --position --sound none|done|request`.
  They have no buttons and no click action for plugins.
- **Keys and links.** `[[keys.command]]` with `type = "plugin_action"`. 0.9.5 has no command
  palette. `[[link_handlers]]` route Ctrl-clicks on URLs matching a regex to a plugin action.
- **Focus.** `workspace focus`, `agent focus`, `tab focus`, `plugin pane focus <pane>` and
  `worktree open --path ... --focus` all exist. `pane get <id>` fails with `pane_not_found` for a
  closed pane.

## Option 1: a full-screen TUI dashboard in a plugin pane

One long-lived pane, a tab in the repo's workspace, showing every stream and acting on the
selected one.

**Live updates.** The plugin already owns a `pane.agent_status_changed` hook, and it can add
`worktree.created` and `worktree.removed` hooks. The hook touches a file in
`HERDR_PLUGIN_STATE_DIR`, and the dashboard reloads when that file is newer than its last load.
Reloads are near-instant, with no socket client, daemon or new dependency. A slow poll of
`herd status -j` (5 s) catches the rest: plan state files and git changes. A compiled TUI could
instead hold an `events.subscribe` connection. Because agent-status subscriptions are per pane,
it would have to resubscribe as streams come and go, which buys little over the hook.

**What to write it in:**

| | bash (+ jq) | bash + gum / fzf | Go + Bubble Tea | Rust + ratatui | Python + Textual |
| --- | --- | --- | --- | --- | --- |
| new runtime deps | none | gum (not common); fzf is optional today | none at run time | none at run time | Python 3.8+ and a venv with textual |
| build | none | none | `go build`, or prebuilt binaries | `cargo build` (minutes), or prebuilt | `pip install` |
| install friction | none: works from `plugin link` and `make install` | gum must be installed | `[[build]]` needs Go on the user's machine, or a release pipeline per OS and arch like the relay's | same as Go, slower | a venv per install; macOS's system Python is old |
| live view | a redraw loop over `read -t` | fzf has no timer; a refresh needs `--listen` plus `--listen-unsafe` for `reload`. gum is forms, not views | rich, true event loop | rich | rich, the richest widgets |
| testable like `tests/plugin.sh` | yes: keys on stdin, faked herdr | partly (fzf is skipped in tests now) | needs Go tests too | needs Rust tests too | needs pytest too |
| Linux / macOS / WSL | yes: bash 4 is already required, and the plugin re-execs Homebrew bash on macOS | yes | yes | yes | yes, with care |
| maintenance | one more bash file; same language as herd | small | a second language and a release matrix | the same, plus Rust | a second language and dependency drift |

**Verdict.** Bash gives about 80% of the value with zero install cost, and it reuses every form
and check herd already has. herd tracks a handful of streams, not hundreds, so a
fuzzy-filtering list isn't needed. Bubble Tea or ratatui become worth it only for things bash
draws badly, like scrollable split panes, mouse, or embedded diffs with syntax colour. Even then
the cost is a second language plus prebuilt binaries for four or more targets, which herd
(no build step today) doesn't have.

## Option 2: a local web UI served by the plugin

A small server on `127.0.0.1` with a page for streams, plans, logs and approvals. It could be
reachable from a phone over a tunnel.

**What the mobile relay shows it takes.** The relay is a Go binary installed by a `[[build]]`
step that downloads a checksum-verified release bundle ("never compiles Go"). It runs as a
systemd user service or a launchd agent, binds `127.0.0.1:8375`, and its event hook forwards
events over loopback UDP (8376). It serves a Svelte app, and for remote access it adds end-to-end
encryption, device pairing by QR code, Cloudflare tunnels or a gateway, push notifications and
an audit log of remote writes. That is the real price of "a browser or phone view": a daemon
herdr won't supervise, a frontend build, auth, and a security story.

**For herd specifically:**

- Shows: the same overview, a plan timeline, PROGRESS.md and diffs rendered as HTML. It's
  better than a terminal for diffs and long logs.
- Does: approvals would mean sending keys to an agent from a browser. That is exactly what the
  relay already does for every agent, herd's included. A herd web UI would duplicate the hardest
  and most security-sensitive part.
- Cost: a server process and its supervision (systemd and launchd units), a port, auth even on
  loopback (other local users, browser CSRF), and a JS or templating layer. herd has none of
  these today.
- Cheapest useful form: a `herd serve` that is read-only, on loopback, rendering
  `herd status -j` plus plan state as one HTML page that refreshes itself. It would be started
  from a plugin pane and die with it, so herdr's lifetime rule holds. Phone access and approvals
  stay with the relay.

## Option 3: a herdr-app JS mod

herdr-app is a desktop app (GPUI, a Vulkan driver on Linux, Apple Silicon builds on macOS, and
Windows). Its mods are JavaScript that describes native GPUI elements, with no HTML or DOM. They
"can run programs (`exec`), read files and use the network", keep state, and open dialogs and
popups. So a mod could run `herd status -j` and draw a rich panel.

The catch is that herdr-app is a client of **herdr-core (`hc`)**, a separate terminal core.
"`herdr-app` controls this app; `hc` controls herdr-core." herd creates its worktrees,
workspaces and agents through the `herdr` CLI and server (`herdr worktree create`,
`herdr agent start`). A herdr-app window wouldn't show those terminals, and a mod couldn't focus
them. Making this work means porting herd's spawning to `hc`, which is a second backend. Both
repos are about three weeks old (created 2026-10-16), and the user doesn't have the app
installed. **Not now.** Revisit if herdr-app or hc replaces the herdr TUI and server, or gains an
API bridge to them.

## Option 4: more from herdr's native surfaces

These are cheap and complement any option:

- **Workspace token on the repo's workspace.** For example `herd=2 working · 1 blocked`, via
  `workspace report-metadata` from the event hook. The Space row then summarises the fan-out
  without opening anything. Rules can colour it, e.g. `contains = "blocked"` in red.
- **State labels.** `--state-label blocked="needs you: stage 2"` on a plan's pane makes the
  sidebar say why it is blocked.
- **`--ttl-ms`** on tokens, so a crashed stream's token doesn't linger.
- **A popup** (`placement = "popup"`, `width = "80%"`) for quick pickers like done or rm, which
  then don't take over the focused pane.
- **`[[link_handlers]]`** for PR URLs, e.g.
  `^https://(github\.com|git\.[^/]+)/[^/]+/[^/]+/pulls?/[0-9]+$`. Ctrl-click a PR link in an
  agent's output to open a herd action for that stream, like done once it's merged.
- **Notifications** can't carry buttons, so they should name the key that acts. The dashboard
  is that key.

None of these can show a timeline, a diff or a form. They are signals that lead to a real view.

## Comparison

| | TUI in a plugin pane (bash) | TUI (Go / Rust) | local web UI | herdr-app mod | native surfaces only |
| --- | --- | --- | --- | --- | --- |
| overview, live | yes, event-nudged | yes, event loop | yes | yes | counts only |
| plan timeline | yes | yes | yes, nicest | yes | stage label only |
| unblock an agent | jump to it | jump to it | needs key-sending from a browser (the relay does this) | no (different core) | notification, then find it |
| launch fan-out, plan, draft | reuses the forms | rewrite the forms | new HTML forms | new forms | no |
| diffs and PRs | pager | pager or widget | best | good | no |
| done and cleanup | yes | yes | yes | no | no |
| new deps | none | toolchain or prebuilt binaries | server, supervisor, frontend | the app plus a port to hc | none |
| install friction | none | high | high | very high | none |
| Linux, macOS, WSL | yes | yes, per-target builds | yes, per-OS services | the app's platforms | yes |
| maintenance | low | medium to high | high | high and moving | very low |

## Recommendation

**Build the TUI dashboard in bash, in a plugin pane, and add the native-surface signals around
it.** It fits herd's shape: bash, no build step, `make test` with a faked herdr. It reuses every
existing form and safety check. It works from `plugin link`, from `make install` and from a
GitHub install the same way. And it covers every job in the table except PR state, which is a
small addition. The web UI is the right tool only for phone access and approvals, which the
mobile relay already provides for herd's agents. A herdr-app mod is blocked on herd running on
a different core.

### Mockup: the dashboard (built on this branch)

```text
herd  ~/git/shop   4 stream(s): 1 blocked · 2 working · 1 idle                      14:02:11
------------------------------------------------------------------------------------------
  BRANCH                             STATUS    PLAN                   WORKSPACE
  feat/export-csv                    working   stage 2/3 running      w5
> fix/login-redirect                 blocked   -                      w6
  feat/search-index                  working   -                      w8
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

With a plan selected, the detail area shows the timeline instead:

```text
feat/export-csv   agent feat-export-csv (working)   ~/git/wt/shop/feat-export-csv
plan  stage 2/3 running
  ✓ 1 Parse the export spec
  ▶ 2 CSV writer with streaming
  · 3 CLI flag and docs
git
  5 commit(s) ahead of origin/main · 0 uncommitted file(s)
progress (.herd/run/PROGRESS.md)
  ## Stage 1
  Parser done; 14 tests. Writer must stream: exports reach 2 GB.
```

### Mockup: the read-only web page (option 2, for later)

```text
+-- herd · shop ----------------------------------------- 1 blocked · 2 working · 1 idle --+
| [!] fix/login-redirect     blocked   "Do you want to make this edit to redirect.ts?"     |
|     -> answer in herdr (or on your phone via the mobile relay)                          |
| [>] feat/export-csv        working   plan  [##########----------]  stage 2/3             |
| [>] feat/search-index      working   3 commits ahead                                     |
| [ ] docs/api               idle      PR #41 open                                         |
+------------------------------------------------------------------------------------------+
| feat/export-csv  ✓ Parse the export spec  ▶ CSV writer with streaming  · CLI flag      |
| PROGRESS.md  |  diff (5 files, +312 -20)  |  agent screen                                |
+------------------------------------------------------------------------------------------+
```

## Roadmap

1. **Dashboard prototype (this branch).** A `dashboard` action and tab pane with a live
   overview, a detail view of the selected stream with its plan timeline, git, progress and
   agent screen, and actions: go, done, discard, resume, fan out, draft, plan, diff, log and
   screen. It is nudged by the event hook (status changes, worktree created and removed) and
   polls every 5 s. Tests are in `tests/plugin.sh`.
2. **Signals (small).** A workspace `$herd` summary token on the repo's workspace, state labels
   on blocked plan panes, a TTL on tokens, and popups for the done and rm pickers. Notifications
   that say "press `<key>` for the dashboard".
3. **Dashboard, round two.** PR state per stream, fetched on demand and cached in the state dir,
   using `pr_lookup` behind a new `herd status -p` or `herd pr` subcommand. Sort blocked first.
   Multi-select for done. Pause polling while the dashboard's tab isn't focused (`pane.focused`
   events). A `[[link_handlers]]` entry for PR URLs.
4. **Web page and phone (done: `herd serve`).** Built further than sketched here: a phone-first
   page and JSON API, on loopback or over NetBird, as a plugin tab or a systemd/launchd service,
   paired with reader and controller tokens. The controller can also start tasks, drafts,
   fan-outs and plans and finish or discard streams. Answering agents stays with the mobile
   relay, which every blocked card deep-links to. See README, "Web page and phone", and
   `docs/serve-api.md`.
5. **Revisit compiled TUI or herdr-app** if bash rendering becomes the bottleneck (mouse,
   scrollable panes), or if herdr-app and hc become where herd's agents run.

## Open questions

- ~~Do you want the read-only web page (step 4), or is the mobile relay enough for away-from-desk?~~
  Answered: both. The relay answers agents; `herd serve` shows the streams and starts herd work
  (README, "Web page and phone").
- Should the dashboard replace the `status` action, or the `menu`, as the one key to bind?
- Is a workspace-level summary token on the repo's workspace welcome, or is it sidebar noise?
