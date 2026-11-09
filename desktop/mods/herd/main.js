// herd in the Herdr app: the focused repo's herd streams (one worktree, space and agent each) with
// their live agent status and plan stage, and buttons for herd's fan-out, plan, draft and done.
// Everything runs bin/herd through exec, with HERD_BACKEND=desktop: the copy bundled in this
// folder (herd/bin/herd) if there is one, else `herd` on PATH. Opened as a dialog (props.dialog),
// the same mod draws herd's forms and pickers instead (dialog.js).
import { View, div } from "gpui-kit";
import { v_flex, h_flex, Scrollbar } from "gpui-base";
import { exec, run, theme, agents, spaces, panes, focused, props, appHome, openOverlay, notify, nextCommand } from "herdr";
import { MOD, parseStreams, streamStatus, streamDetail, sortStreams, mainCheckout, baseName, draftName, encode, decode, lastLine } from "./lib.js";
import { Dialog } from "./dialog.js";

const POLL = 6000;        // ms: new streams and plan stages (agent status itself is live)
const LONG = 600_000;     // ms: exec's cap, for a fan-out or a draft
const SPIN = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

class Panel {
  init(cx) {
    this.folder = null;      // the focused terminal's folder the repo was read from
    this.repo = undefined;   // { main, name }; null: not in git; undefined: looking
    this.streams = [];
    this.error = "";
    this.loading = false;
    this.jobs = [];          // { id, label, running, ok, out }
    this.herd = "herd";
    cx.spawn(async (cx) => {
      const bundled = `${appHome()}/mods/${MOD}/herd/bin/herd`;
      try { if ((await exec("test", ["-x", bundled])).code === 0) this.herd = bundled; } catch {}
      this.refresh(cx);
    });
    cx.timer.every(POLL, (cx) => this.refresh(cx));
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        // Each in its own task: a fan-out runs for minutes, and a notice must not wait behind it.
        cx.spawn(async (cx) => {
          try { await this.command(c, cx); } catch (e) { this.toast("herd", String(e), "error"); }
          cx.notify();
        });
      }
    });
  }

  // Where the person is: the focused terminal's folder, else the shown space's first terminal's.
  where() {
    const f = focused();
    if (f?.cwd) return f.cwd;
    const s = spaces().find((x) => x.active);
    const tabs = new Set((s?.tabs ?? []).map((t) => t.id));
    return panes().find((p) => tabs.has(p.tab) && p.cwd)?.cwd ?? null;
  }

  sync(folder, cx) {
    this.folder = folder;
    cx.spawn(async (cx) => {
      let repo = null;
      try {
        const r = await exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd: folder });
        if (r.code === 0) { const main = mainCheckout(r.stdout); repo = { main, name: baseName(main) }; }
      } catch {}
      if (this.folder !== folder) return;   // focus moved on meanwhile
      if (repo?.main === this.repo?.main && this.repo !== undefined) return;
      this.repo = repo;
      this.streams = [];
      this.error = "";
      cx.notify();
      this.refresh(cx);
    });
  }

  herdExec(args, timeout = 30_000) {
    return exec("env", ["HERD_BACKEND=desktop", this.herd, ...args], { cwd: this.repo.main, timeout });
  }

  refresh(cx) {
    if (!this.repo || this.loading) return;
    const repo = this.repo;
    this.loading = true;
    cx.spawn(async (cx) => {
      try {
        const r = await this.herdExec(["status", "-j", "-r", repo.main]);
        if (this.repo?.main !== repo.main) return;
        this.streams = parseStreams(r.stdout);
        this.error = r.code === 0 ? "" : lastLine(r.stderr) || `herd status exited ${r.code}`;
      } catch (e) { this.error = String(e); }
      finally { this.loading = false; cx.notify(); }
    });
  }

  toast(title, body, level = "info", action) {
    notify({ title, body, level, timeout: level === "error" ? 12000 : 6000, ...(action ? { action } : {}) });
  }

  // A herd run in the background: shown in the footer while it runs, then as a toast.
  async job(label, args, cx, timeout = LONG) {
    const job = { id: Date.now() + Math.random(), label, running: true, ok: false, out: "" };
    this.jobs = [...this.jobs.slice(-9), job];
    cx.notify();
    try {
      const r = await this.herdExec(args, timeout);
      job.ok = r.code === 0;
      job.out = [r.stdout, r.stderr].filter((s) => s.trim()).join("\n");
    } catch (e) { job.out = String(e); }
    job.running = false;
    this.toast(`herd ${label}`, lastLine(job.out) || (job.ok ? "done" : "failed"), job.ok ? "success" : "error", { name: `${MOD}.log` });
    this.refresh(cx);
    cx.notify();
    return job;
  }

  async command(c, cx) {
    const { name, data } = decode(c);
    // From herd itself (an agent waiting on a question only the person can answer): any repo.
    if (name === "notice") {
      return this.toast(data?.title ?? "herd", data?.body ?? "", "warning", data?.space ? { name: "space.select", args: { id: data.space } } : undefined);
    }
    if (!this.repo && name !== "refresh") return this.toast("herd", "Focus a terminal in a git repository first.", "warning");
    if (name === "refresh") return this.refresh(cx);
    if (name === "log") return this.showLog();
    if (name === "fanout" && data === null) return this.askFanout();
    if (name === "fanout-ask") return this.confirmFanout(data);
    if (name === "fanout") return this.job(`fan-out (${data})`, ["-f", data], cx);
    if (name === "plan" && data === null) return this.askPlan();
    if (name === "plan") return this.startPlan(data);
    if (name === "draft" && data === null) return this.askDraft();
    if (name === "draft") {
      const j = await this.job(`draft → ${data.out}`, ["draft", "-o", data.out, data.goal], cx);
      if (j.ok) this.toast("herd draft", `Wrote ${data.out}. Fan out to start it.`, "success", { name: encode("fanout-ask", data.out) });
      return;
    }
    if (name === "done") return this.job(`done ${data}`, ["done", data], cx, 180_000);
  }

  async files(pattern) {
    const r = await exec("sh", ["-c", `ls -1d ${pattern} 2>/dev/null; true`], { cwd: this.repo.main });
    return r.stdout.split("\n").map((l) => l.trim()).filter(Boolean);
  }

  dialog(p, width = 520, height = 340) {
    openOverlay({ mod: MOD, kind: "dialog", width, height, props: { repo: this.repo.main, ...p } });
  }

  async askFanout() {
    const list = await this.files("Tasks*.herd");
    if (list.length === 0) return this.toast("herd", `No Tasks.herd in ${this.repo.name}. Draft one first.`, "warning", { name: `${MOD}.draft` });
    if (list.length === 1) return this.confirmFanout(list[0]);
    this.dialog({ dialog: "pick", title: "Fan out which task file?", items: list, command: "fanout-ask" }, 420, 300);
  }

  // The shipped confirm dialog, showing herd's dry run of the file.
  async confirmFanout(file) {
    const r = await this.herdExec(["-n", "-f", file]);
    if (r.code !== 0) return this.toast("herd", lastLine(r.stderr) || `${file} has problems`, "error");
    const n = r.stdout.split("\n").filter((l) => l.trim()).length;
    openOverlay({
      mod: "confirm", kind: "dialog", width: 640, height: Math.min(480, 230 + n * 22),
      props: {
        title: `Fan out ${n} task${n === 1 ? "" : "s"} from ${file}?`,
        detail: `Each gets a worktree under ~/git/wt/${this.repo.name}/, a space and an agent:\n\n${r.stdout.trim()}`,
        command: { name: encode("fanout", file) },
      },
    });
  }

  async askPlan() {
    const plans = (await this.files("*.md .herd/*.md docs/*.md")).filter((f) => !/^(README|CHANGELOG|LICENSE|CLAUDE|AGENTS)/i.test(baseName(f)));
    this.dialog({
      dialog: "form", title: `Plan in ${this.repo.name}`, submit: { name: "plan", label: "Start plan" },
      hint: "Runs herd plan in a new tab: a planner splits the plan into gated stages, one fresh session each.",
      fields: [
        { key: "branch", label: "Branch", placeholder: "feat/thing" },
        { key: "plan", label: "Plan: a file in the repo, or the plan itself", placeholder: "PLAN.md" },
      ],
      choices: { field: "plan", items: plans },
    }, 540, plans.length ? 400 : 330);
  }

  // A plan drives its stages for as long as they take, so it runs in a tab, where its log shows.
  startPlan({ branch, plan }) {
    const space = spaces().find((s) => s.active);
    run("tab.new", {
      space: space?.id, name: `plan ${branch}`, folder: this.repo.main,
      argv: ["env", "HERD_BACKEND=desktop", this.herd, "plan", branch, plan],
    });
  }

  async askDraft() {
    const out = draftName(await this.files("Tasks*.herd"));
    this.dialog({
      dialog: "form", title: `Draft tasks for ${this.repo.name}`, submit: { name: "draft", label: "Draft" },
      hint: "A read-only dispatcher agent reads the repo and writes one task line per parallel task (a minute or two).",
      fields: [
        { key: "goal", label: "Goal", placeholder: "what should get done" },
        { key: "out", label: "Task file", value: out },
      ],
    });
  }

  askDone(s) {
    openOverlay({
      mod: "confirm", kind: "dialog", width: 480, height: 220,
      props: {
        title: `Finish ${s.branch}?`,
        detail: "herd done checks that its PR is merged, its agent idle and its tree clean, then removes the worktree, the space and the local and remote branch.",
        command: { name: encode("done", s.branch) },
      },
    });
  }

  showLog() {
    const j = [...this.jobs].reverse().find((x) => !x.running);
    if (!j) return;
    this.dialog({ dialog: "log", title: `herd ${j.label}`, text: j.out || "(no output)", ok: j.ok }, 680, 460);
  }

  button(id, label, primary, action) {
    const t = theme();
    return h_flex().id(id).flex_1().h(28).px(8).justify_center().items_center().rounded(7).border_1()
      .border_color(primary ? t.solid : t.input).bg(primary ? t.solid : t.raised)
      .text_color(primary ? t.solid_foreground : t.foreground).text_size(12).font_medium().cursor_pointer()
      .hover((s) => s.opacity(0.88))
      .on_click((_e, cx) => { if (!this.repo) return; cx.spawn(async (cx) => { try { await action(); } catch (e) { this.toast("herd", String(e), "error"); } cx.notify(); }); })
      .child(label);
  }

  row(s, t) {
    const color = s.status ? (t[s.status] ?? t.dim) : t.dim;
    const open = s.workspace && s.workspace !== "-" && spaces().some((x) => x.id === s.workspace);
    const shown = open && spaces().find((x) => x.id === s.workspace)?.active;
    return h_flex().id(`row-${s.branch}`).flex_none().h(46).px(8).gap(10).items_center().rounded(7)
      .when(shown, (el) => el.bg(t.selected))
      .when(!shown, (el) => el.hover((h) => h.bg(t.hover)))
      .when(open, (el) => el.cursor_pointer().on_click(() => run("space.select", { id: s.workspace })))
      .child(div().flex_none().w(8).h(8).rounded(4).bg(color)
        .when(s.status === "working", (el) => el.loop("opacity", { from: 0.35, to: 1, period: 1200 })))
      .child(v_flex().flex_1().min_w(0).gap(2)
        .child(div().truncate().child(s.branch))
        .child(div().truncate().text_size(11.5).text_color(s.status === "blocked" ? t.blocked : t.dim).child(streamDetail(s, s.status))))
      .child(h_flex().id(`done-${s.branch}`).flex_none().h(24).px(8).items_center().rounded(6).border_1().border_color(t.input)
        .text_size(11).text_color(t.muted).cursor_pointer().hover((h) => h.bg(t.raised).text_color(t.foreground))
        .on_click((_e, cx) => { cx.stop_propagation(); this.askDone(s); })
        .child("Done"));
  }

  footer(t) {
    const running = this.jobs.filter((j) => j.running);
    const last = [...this.jobs].reverse().find((j) => !j.running);
    if (!running.length && !last) return null;
    const bar = h_flex().id("herd-footer").flex_none().h(30).px(12).gap(8).items_center().border_t(1).border_color(t.border).text_size(11.5);
    if (running.length) {
      return bar.child(div().flex_none().text_color(t.working).frames(SPIN, 90))
        .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(running.map((j) => j.label).join(", ") + "…"));
    }
    return bar.cursor_pointer().hover((h) => h.bg(t.hover)).on_click(() => this.showLog())
      .child(div().flex_none().text_color(last.ok ? t.working : t.blocked).child(last.ok ? "✓" : "✗"))
      .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(`${last.label}: ${lastLine(last.out) || (last.ok ? "done" : "failed")}`));
  }

  render(cx) {
    const where = this.where();
    if (where && where !== this.folder) this.sync(where, cx);
    const t = theme();
    const live = agents();
    const rows = sortStreams(this.streams.map((s) => ({ ...s, status: streamStatus(s, live) })));
    const r = this.repo;
    const empty = r === undefined ? "Looking for the repo…"
      : r === null ? "Focus a terminal in a git repository to see its herd streams."
      : this.error ? this.error
      : rows.length === 0 ? `No herd streams in ${r.name} yet. Fan out from Tasks.herd, start a plan, or draft tasks.` : "";
    return v_flex().id("herd").size_full().min_h(0).rounded(10).overflow_hidden().bg(t.background).border_1().border_color(t.border)
      .text_color(t.foreground).text_size(13)
      .child(h_flex().h(42).flex_none().px(14).gap(8).items_center().border_b(1).border_color(t.border)
        .child(div().font_semibold().child("Herd"))
        .when(Boolean(r), (el) => el.child(div().min_w(0).truncate().text_color(t.muted).child(r.name)))
        .when(rows.length > 0, (el) => el.child(div().flex_none().px(5).py(1).rounded(4).border_1().border_color(t.border).text_size(10).text_color(t.muted).child(`${rows.length} stream${rows.length === 1 ? "" : "s"}`)))
        .child(div().flex_1())
        .child(h_flex().id("herd-refresh").flex_none().w(22).h(22).justify_center().items_center().rounded(5).text_color(t.dim).cursor_pointer()
          .hover((h) => h.bg(t.hover).text_color(t.foreground)).on_click((_e, cx) => this.refresh(cx))
          .child(this.loading ? div().frames(SPIN, 90) : div().child("⟳"))))
      .child(h_flex().flex_none().px(10).py(8).gap(6).border_b(1).border_color(t.border)
        .child(this.button("herd-fanout", "Fan out", true, () => this.askFanout()))
        .child(this.button("herd-plan", "Plan…", false, () => this.askPlan()))
        .child(this.button("herd-draft", "Draft…", false, () => this.askDraft())))
      .child(div().flex_1().min_h(0).relative()
        .child(v_flex().id("herd-list").absolute().inset_0().overflow_y_scroll().p(6).gap(2)
          .children(rows.map((s) => this.row(s, t)))
          .when(Boolean(empty), (el) => el.child(div().p(8).text_color(this.error ? t.blocked : t.dim).child(empty))))
        .child(Scrollbar.vertical("herd-list").absolute().inset_0()))
      .when(Boolean(this.footer(t)), (el) => el.child(this.footer(t)));
  }
}

export default class Herd extends View {
  init(_props, cx) {
    this.impl = props()?.dialog ? new Dialog() : new Panel();
    this.impl.init(cx);
  }

  render(cx) {
    return this.impl.render(cx);
  }
}
