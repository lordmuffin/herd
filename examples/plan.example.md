# A pre-staged plan for herd plan
#
#   herd plan feat/export-csv examples/plan.example.md
#
# Because this file already has "## Stage N: title" headings, herd skips the planner and runs
# these stages as written. Leave the headings out and herd has a planner agent write them first
# (into .herd/run/stages.md in the worktree; use -n to stop there and review them).
#
# Each stage runs in a fresh agent session in the same worktree. herd adds the handoff rules to
# every prompt: read .herd/run/PROGRESS.md, commit, append a "## Stage N" section to it, and, in
# the last stage only, push and open the PR. A stage's first "verify:" line is the command herd
# runs before moving on (-v gives a default for stages without one). Everything above the first
# heading, like this comment, is kept in .herd/run/plan.md for the agents' context only.
#
# herd gates a stage only once its turn has ended and the agent has no background shell or
# Monitor still running (it waits up to -W minutes, default 60). A stage that may need to stop
# the whole run says so in its prompt: herd stops at once, with no fix-up turn, when PROGRESS.md
# has a line starting "STOPPED:", as stage 1 does below.

## Stage 1: Export model
verify: make test

Add a `to_csv_rows()` function next to the existing `to_json()` in src/report.py, returning a
header row and one row per entry, using the same field order as `to_json()`. Add unit tests for an
empty report and a report with a comma inside a field.
If src/report.py has no `to_json()`, this plan is out of date: write
`STOPPED: no to_json() in src/report.py` to .herd/run/PROGRESS.md and end your turn.

## Stage 2: CLI flag
verify: make test

Add `--format csv` to the `report` subcommand in src/cli.py, using `to_csv_rows()` from stage 1
and the csv module's writer. `--format json` stays the default. Extend tests/test_cli.py to cover it.

## Stage 3: Docs
verify: make test

Document `--format csv` in README.md's Usage section, with one example, matching the voice and
code-fence style of the surrounding text.
