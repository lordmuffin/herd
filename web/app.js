// herd's page: the streams of `herd serve`, phone first. Vanilla JS, no build, no network but
// this server. The data is herd's own JSON (docs/serve-api.md): /api/snapshot over the event
// stream, /api/show for a stream's text, /api/config for the relay deep link's settings.
// With the controller token, the New sheet and the detail view's buttons POST to the write routes
// (/api/start, draft, fanout, plan, plan-resume, done, rm), which run herd on the computer.
//
// Answering an agent happens in the Herdr Mobile app, not here: every stream links to it with the
// relay's deep link, <app url>/#notify=<encodeURIComponent(JSON.stringify({pane_id, host}))>.
"use strict";

const TOKEN_KEY = "herd.token";
const STATUS_RANK = { blocked: 0, working: 1, idle: 2, done: 3 };
const SCREEN_LINES = 6; // lines of a blocked agent's screen shown as its question
const FETCH_TIMEOUT = 15000;
const BACKOFF_MIN = 1000;
const BACKOFF_MAX = 30000;
const REPO_KEY = "herd.repo";
const PERSONA_KEY = "herd.persona";
const RECENT_KEY = "herd.recent";
const RECENT_MAX = 10;
// A write waits as long as the server lets herd run it: a draft or a fan-out runs agents.
const WRITE_WAIT = { start: 330e3, draft: 930e3, fanout: 930e3, plan: 90e3, done: 330e3, rm: 150e3 };

const state = {
  token: null,
  config: null, // {relay_app_url, relay_host, read_only, repos, role}
  snap: null, // the last snapshot
  lastUpdate: null, // Date of the last snapshot
  live: false,
  es: null,
  backoff: BACKOFF_MIN,
  retryTimer: null,
  screens: new Map(), // "repo\nbranch" -> {text, status} for blocked cards
  detail: null, // {repo, branch} while the detail view is open
  tab: "progress",
  tabSeq: 0,
  personas: new Map(), // repo -> [{name, description}] for the persona pickers
  drafted: null, // {repo, file, hash} of the last draft, for its Fan out button
};

const $ = (id) => document.getElementById(id);

// h("div.card", {onclick}, child, "text"): an element. Text only ever goes in as text nodes.
function h(tag, attrs, ...kids) {
  const [name, ...classes] = tag.split(".");
  const el = document.createElement(name);
  if (classes.length) el.className = classes.join(" ");
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "text") el.textContent = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

// --- storage, pairing --------------------------------------------------------------------------

function store(key, value) {
  try {
    if (value == null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch (e) {
    /* private mode: the token lives for this page only */
  }
}

function load(key) {
  try {
    return localStorage.getItem(key);
  } catch (e) {
    return null;
  }
}

// A #t=<token> fragment (from `herd serve pair`) pairs this device: keep it and take it out of
// the address bar, so it isn't in history, bookmarks or a screenshot.
function takeTokenFromUrl() {
  const m = /(?:^#|&)t=([^&]+)/.exec(location.hash);
  if (!m) return;
  store(TOKEN_KEY, decodeURIComponent(m[1]));
  history.replaceState(null, "", location.pathname + location.search);
}

function forget() {
  store(TOKEN_KEY, null);
  state.token = null;
  state.snap = null;
  state.config = null;
  state.screens.clear();
  disconnect();
  hideSheet();
  showPair("");
}

// --- network ------------------------------------------------------------------------------------

// An /api request, its answer as JSON. Never throws: {ok, status, data}.
async function request(path, init, timeout) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeout || FETCH_TIMEOUT);
  try {
    const res = await fetch(path, {
      ...init,
      headers: { Authorization: "Bearer " + state.token, ...(init.headers || {}) },
      cache: "no-store",
      signal: ctl.signal,
    });
    let data = null;
    try {
      data = await res.json();
    } catch (e) {
      /* not JSON */
    }
    return { ok: res.ok, status: res.status, data };
  } catch (e) {
    return { ok: false, status: 0, data: null };
  } finally {
    clearTimeout(timer);
  }
}

// GET an /api route.
const api = (path) => request(path, {});

// POST a JSON body to an /api route. The server answers {ok, output, error, request_id}.
const post = (path, body, timeout) =>
  request(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }, timeout);

function connect() {
  disconnect();
  // A reconnect keeps saying "offline, last update hh:mm" until a snapshot arrives.
  setConn(false, state.lastUpdate ? null : "connecting");
  // EventSource can't send headers: /api/events is the one route that takes ?t=.
  const es = new EventSource("/api/events?t=" + encodeURIComponent(state.token));
  state.es = es;
  es.addEventListener("snapshot", (ev) => {
    let snap;
    try {
      snap = JSON.parse(ev.data);
    } catch (e) {
      return;
    }
    state.backoff = BACKOFF_MIN;
    state.lastUpdate = new Date();
    setConn(true);
    onSnapshot(snap);
  });
  es.addEventListener("error", (ev) => {
    // A named `error` event from the server carries data (herd failed); keep the stream.
    if (ev.data) {
      setConn(true, "herd: " + safeError(ev.data));
      return;
    }
    // The connection dropped. Back off and reconnect ourselves, and find out whether the token
    // is still good (EventSource doesn't say why it failed).
    es.close();
    if (state.es !== es) return;
    state.es = null;
    setConn(false);
    scheduleReconnect();
  });
}

function safeError(data) {
  try {
    return JSON.parse(data).error || "error";
  } catch (e) {
    return "error";
  }
}

function disconnect() {
  clearTimeout(state.retryTimer);
  state.retryTimer = null;
  if (state.es) {
    state.es.close();
    state.es = null;
  }
}

function scheduleReconnect() {
  clearTimeout(state.retryTimer);
  const wait = state.backoff;
  state.backoff = Math.min(state.backoff * 2, BACKOFF_MAX);
  state.retryTimer = setTimeout(async () => {
    state.retryTimer = null;
    if (!state.token) return;
    const r = await api("/api/config");
    if (r.status === 401) return showPair("This device's token was not accepted. Pair it again.");
    if (r.ok) setConfig(r.data);
    if (r.ok) connect();
    else scheduleReconnect();
  }, wait);
}

// --- connection status --------------------------------------------------------------------------

function hhmm(d) {
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false });
}

function setConn(live, text) {
  state.live = live;
  const conn = $("conn");
  conn.classList.toggle("live", live);
  conn.classList.toggle("offline", !live);
  let label = text;
  if (!label) label = live ? "live" : state.lastUpdate ? "offline, last update " + hhmm(state.lastUpdate) : "offline";
  $("conn-text").textContent = label;
}

// --- the overview -------------------------------------------------------------------------------

const key = (repo, branch) => repo + "\n" + branch;
const rank = (s) => (s in STATUS_RANK ? STATUS_RANK[s] : 4);

function allStreams(snap) {
  const out = [];
  for (const r of snap.repos || []) for (const s of r.streams || []) out.push({ repo: r, s });
  return out;
}

function findStream(repo, branch) {
  if (!state.snap) return null;
  for (const { repo: r, s } of allStreams(state.snap)) if (r.path === repo && s.branch === branch) return { repo: r, s };
  return null;
}

function onSnapshot(snap) {
  state.snap = snap;
  // Forget screens of streams that stopped being blocked, so a new question is fetched fresh.
  const blocked = new Set();
  for (const { repo, s } of allStreams(snap)) if (s.status === "blocked") blocked.add(key(repo.path, s.branch));
  for (const k of state.screens.keys()) if (!blocked.has(k)) state.screens.delete(k);
  render();
}

function counts(snap) {
  const n = {};
  for (const { s } of allStreams(snap)) {
    const st = s.status === "-" ? "no agent" : s.status || "unknown";
    n[st] = (n[st] || 0) + 1;
  }
  const order = ["blocked", "working", "idle", "done"];
  const keys = order.filter((k) => n[k]).concat(Object.keys(n).filter((k) => !order.includes(k)).sort());
  return keys.map((k) => n[k] + " " + k).join(" · ");
}

function render() {
  const snap = state.snap;
  $("pair").hidden = true;
  $("forget").hidden = false;
  if (!snap) return;
  $("host").textContent = snap.host ? " · " + snap.host : "";
  $("counts").textContent = counts(snap) || "no streams";
  if (state.detail) renderDetailHead();
  updateFab();
  $("overview").hidden = !!state.detail;
  $("detail").hidden = !state.detail;

  const repos = (snap.repos || []).filter((r) => (r.streams || []).length);
  $("empty").hidden = repos.length > 0;
  // Repos with a blocked stream first, then by path; in a repo, blocked, working, idle, done.
  const ordered = repos
    .map((r) => ({ r, top: Math.min(...r.streams.map((s) => rank(s.status))) }))
    .sort((a, b) => a.top - b.top || a.r.path.localeCompare(b.r.path));
  const box = $("repos");
  box.replaceChildren(
    ...ordered.map(({ r }) =>
      h(
        "section.repo",
        null,
        h("h2.repo-name", { title: r.path }, r.repo),
        r.streams
          .map((s, i) => ({ s, i }))
          .sort((a, b) => rank(a.s.status) - rank(b.s.status) || a.i - b.i)
          .map(({ s }) => card(r, s)),
      ),
    ),
  );
}

function pill(status) {
  const st = status === "-" ? "none" : status || "unknown";
  return h("span.pill.st-" + st.replace(/[^a-z]/g, ""), null, status === "-" ? "no agent" : st);
}

// {done, total, label} for a plan, or null without one.
function planProgress(s) {
  const p = s.plan_detail;
  if (!p) return s.plan ? { done: 0, total: 0, label: s.plan } : null;
  const stages = p.stages || [];
  if (!stages.length) return { done: 0, total: 0, label: p.status || s.plan || "plan" };
  const done = stages.filter((x) => x.state === "done").length;
  const at = stages.find((x) => x.state === "current" || x.state === "stopped");
  const label = at ? "stage " + at.n + "/" + stages.length : p.status === "complete" ? "complete" : "stage " + done + "/" + stages.length;
  return { done, total: stages.length, label, stopped: !!(at && at.state === "stopped") };
}

function planBar(s) {
  const pp = planProgress(s);
  if (!pp) return null;
  const fill = h("span.bar-fill" + (pp.stopped ? ".stopped" : ""));
  fill.style.width = pp.total ? Math.round((100 * pp.done) / pp.total) + "%" : "0%";
  return h(
    "div.plan",
    null,
    h("span.bar", { role: "progressbar", "aria-label": "plan", "aria-valuemin": "0", "aria-valuemax": String(pp.total), "aria-valuenow": String(pp.done) }, fill),
    h("span.plan-label", null, pp.label),
  );
}

function gitLine(s) {
  const bits = [];
  if (s.ahead != null) bits.push(s.ahead + " ahead");
  if (s.dirty != null) bits.push(s.dirty + " dirty");
  return bits.length ? h("p.git", null, bits.join(" · ")) : null;
}

// The relay deep link for a stream, or null without an app URL or a pane.
function relayLink(s) {
  const app = state.config && state.config.relay_app_url;
  if (!app || !s.pane_id) return null;
  let base;
  try {
    base = new URL(app);
  } catch (e) {
    return null;
  }
  if (base.protocol !== "https:" && base.protocol !== "http:") return null;
  base.hash = "";
  const host = s.host || (state.config && state.config.relay_host) || (state.snap && state.snap.host);
  return base.href + "#notify=" + encodeURIComponent(JSON.stringify({ pane_id: s.pane_id, host }));
}

function relayButton(s) {
  const href = relayLink(s);
  if (href) return h("a.relay", { href, target: "_blank", rel: "noopener noreferrer" }, "Open in Herdr Mobile");
  if (!(state.config && state.config.relay_app_url)) return h("p.hint", null, "Set HERD_RELAY_APP_URL in herd.conf to answer from the phone.");
  return h("p.hint", null, "No agent pane to open.");
}

function card(r, s) {
  const blocked = s.status === "blocked";
  const main = h(
    "button.card-main",
    { type: "button", onclick: () => openDetail(r.path, s.branch), "aria-label": s.branch + ", " + (s.status === "-" ? "no agent" : s.status) + ": open details" },
    h("span.card-top", null, h("span.branch", null, s.branch), pill(s.status)),
    planBar(s),
    gitLine(s),
    s.last_commit ? h("span.commit", null, s.last_commit.subject + " · " + s.last_commit.rel_time) : null,
  );
  const kids = [main];
  if (blocked) {
    kids.push(question(r, s));
    kids.push(relayButton(s));
  }
  return h("article.card" + (blocked ? ".blocked" : ""), null, kids);
}

// The blocked agent's question: the last lines of its screen, fetched once per blocked spell.
function question(r, s) {
  const k = key(r.path, s.branch);
  const pre = h("pre.question", { "aria-label": "the agent's screen" });
  const shown = state.screens.get(k);
  if (shown) {
    pre.textContent = shown.text;
  } else {
    pre.textContent = "loading the agent's screen…";
    state.screens.set(k, { text: pre.textContent, loading: true });
    api("/api/show?" + new URLSearchParams({ repo: r.path, branch: s.branch, what: "screen" })).then((res) => {
      const text = res.ok ? lastLines(res.data.text, SCREEN_LINES) || "(the screen is empty)" : "could not read the screen";
      if (!state.screens.has(k)) return;
      state.screens.set(k, { text });
      if (!state.detail) render();
    });
  }
  return pre;
}

function lastLines(text, n) {
  const lines = (text || "").replace(/\s+$/, "").split("\n");
  return lines.slice(-n).join("\n");
}

// --- the detail view ----------------------------------------------------------------------------

function openDetail(repo, branch) {
  state.detail = { repo, branch };
  history.pushState({ detail: true }, "");
  resetActions();
  render();
  window.scrollTo(0, 0);
  selectTab(state.tab);
}

function closeDetail() {
  state.detail = null;
  render();
}

const MARK = { done: "✓", current: "▶", stopped: "!", todo: "·" };

function renderDetailHead() {
  const { repo, branch } = state.detail;
  const found = findStream(repo, branch);
  const head = $("detail-head");
  if (!found) {
    head.replaceChildren(h("h2.d-branch", null, branch), h("p.hint", null, "This stream is gone: it was finished or discarded."));
    for (const id of ["act-resume", "act-done", "act-discard", "discard-confirm"]) $(id).hidden = true;
    return;
  }
  const { repo: r, s } = found;
  const p = s.plan_detail;
  $("act-resume").hidden = !(p && p.status !== "complete");
  $("act-done").hidden = $("act-discard").hidden = false;
  const timeline = p && (p.stages || []).length
    ? h(
        "ol.timeline",
        { "aria-label": "plan" },
        p.stages.map((st) =>
          h(
            "li.st-" + st.state,
            null,
            h("span.mark", { "aria-hidden": "true" }, MARK[st.state] || "·"),
            h("span.t", null, h("span.sr", null, st.state + ": "), st.n + " " + st.title),
            st.state === "stopped" && p.stopped_reason ? h("span.reason", null, p.stopped_reason) : null,
          ),
        ),
      )
    : p
      ? h("p.hint", null, "plan: " + (p.status || "starting"))
      : null;
  head.replaceChildren(
    h("p.d-repo", { title: r.path }, r.repo),
    h("div.card-top", null, h("h2.d-branch", null, s.branch), pill(s.status)),
    planBar(s),
    gitLine(s),
    s.last_commit ? h("p.commit", null, s.last_commit.sha + " " + s.last_commit.subject + " · " + s.last_commit.rel_time) : null,
    relayButton(s),
    timeline,
  );
}

async function selectTab(what) {
  state.tab = what;
  for (const b of document.querySelectorAll("#detail .tabs [role=tab]")) b.setAttribute("aria-selected", String(b.dataset.what === what));
  const pre = $("tab-text");
  if (!state.detail) return;
  const { repo, branch } = state.detail;
  const seq = ++state.tabSeq;
  pre.className = "text" + (what === "diff" ? " diff" : "");
  pre.textContent = "loading…";
  $("tab-note").textContent = "";
  const res = await api("/api/show?" + new URLSearchParams({ repo, branch, what }));
  if (seq !== state.tabSeq) return; // another tab or stream took over meanwhile
  if (!res.ok) {
    pre.textContent = res.status === 0 ? "offline: could not load this" : (res.data && res.data.error) || "error " + res.status;
    return;
  }
  const text = res.data.text || "";
  $("tab-note").textContent = res.data.truncated ? "cut at 200 KB" : "";
  if (!text) {
    pre.textContent = { progress: "(no PROGRESS.md)", diff: "(no changes)", log: "(no commits ahead)", screen: "(no agent screen)" }[what];
    return;
  }
  if (what === "diff") {
    pre.replaceChildren(...text.split("\n").map((line) => h("span" + diffClass(line), null, line + "\n")));
  } else {
    pre.textContent = text;
  }
}

function diffClass(line) {
  if (line.startsWith("@@")) return ".hunk";
  if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("diff ") || line.startsWith("index ")) return ".file";
  if (line.startsWith("+")) return ".add";
  if (line.startsWith("-")) return ".del";
  return "";
}

// --- writes: shared -----------------------------------------------------------------------------

function setConfig(config) {
  state.config = config;
  updateFab();
  if (state.detail) $("detail-actions").hidden = !canWrite();
}

// Only the controller token may write, and only when herd serve isn't --read-only.
const canWrite = () => !!(state.token && state.config && state.config.role === "controller" && !state.config.read_only);

function updateFab() {
  $("new").hidden = !canWrite() || !!state.detail || !$("sheet").hidden;
}

// Shows a write's answer in a <pre>: herd's output, its error, the request id.
function showResult(pre, res) {
  const d = res.data || {};
  const good = res.ok && d.ok === true;
  let text;
  if (res.status === 0) {
    text = "No answer from herd serve: offline, or it took too long. Check on the computer before trying again; it may have run.";
  } else {
    const out = (d.output || "").trim();
    text = [out, d.error && !out.includes(d.error) ? d.error : null].filter(Boolean).join("\n") || (good ? "done" : "error " + res.status);
  }
  if (d.request_id) text += "\n(request " + d.request_id + ")";
  pre.textContent = text;
  pre.classList.toggle("good", good);
  pre.classList.toggle("bad", !good);
  pre.hidden = false;
  return good;
}

// Runs one write with its button(s) disabled and "busy" as the label meanwhile.
async function runWrite(buttons, busy, pre, path, body, timeout) {
  const labels = buttons.map((b) => b.textContent);
  for (const b of buttons) b.disabled = true;
  if (buttons[0]) buttons[0].textContent = busy;
  pre.hidden = false;
  pre.classList.remove("good", "bad");
  pre.textContent = busy;
  const res = await post(path, body, timeout);
  buttons.forEach((b, i) => {
    b.disabled = false;
    b.textContent = labels[i];
  });
  return { res, good: showResult(pre, res) };
}

function basename(p) {
  return p.replace(/\/+$/, "").split("/").pop() || p;
}

// The repos the sheet offers: those with streams, then HERD_SERVE_REPOS.
function repoList() {
  const seen = new Map();
  for (const r of (state.snap && state.snap.repos) || []) seen.set(r.path, r.repo || basename(r.path));
  for (const p of (state.config && state.config.repos) || []) if (!seen.has(p)) seen.set(p, basename(p));
  return [...seen].map(([path, name]) => ({ path, name }));
}

function fillRepos() {
  const repos = repoList();
  const want = load(REPO_KEY);
  for (const sel of document.querySelectorAll(".repo-pick")) {
    const cur = sel.value || want;
    if (!repos.length) {
      sel.replaceChildren(h("option", { value: "" }, "no repos: set HERD_SERVE_REPOS in herd.conf"));
      continue;
    }
    sel.replaceChildren(...repos.map((r) => h("option", { value: r.path, title: r.path }, r.name + " · " + r.path)));
    if (repos.some((r) => r.path === cur)) sel.value = cur;
  }
}

// Fills a form's persona picker with `herd personas` for its repo.
async function fillPersonas(form) {
  const sel = form.elements.persona;
  if (!sel) return;
  const repo = form.elements.repo.value;
  if (!state.personas.has(repo)) {
    const r = await api("/api/personas?" + new URLSearchParams({ repo }));
    if (r.ok) state.personas.set(repo, r.data.personas || []);
  }
  const list = state.personas.get(repo) || [];
  const cur = sel.value || load(PERSONA_KEY) || "";
  sel.replaceChildren(
    h("option", { value: "" }, "herd's default"),
    h("option", { value: "none" }, "none (the prompt alone)"),
    ...list.map((p) => h("option", { value: p.name, title: p.description || "" }, p.name)),
  );
  if ([...sel.options].some((o) => o.value === cur)) sel.value = cur;
}

function remember(body) {
  if (body.repo) store(REPO_KEY, body.repo);
  if (body.persona != null) store(PERSONA_KEY, body.persona);
}

// --- writes: the New sheet ------------------------------------------------------------------------

function openSheet() {
  if (!canWrite()) return;
  history.pushState({ sheet: true }, "");
  $("sheet").hidden = false;
  document.body.classList.add("sheet-open");
  updateFab();
  fillRepos();
  for (const f of document.querySelectorAll("#sheet form")) fillPersonas(f);
  renderRecent();
  const open = document.querySelector("#sheet form:not([hidden]) textarea");
  if (open) open.focus();
}

function hideSheet() {
  $("sheet").hidden = true;
  document.body.classList.remove("sheet-open");
  updateFab();
}

function selectForm(name) {
  for (const b of document.querySelectorAll("#sheet [role=tab]")) b.setAttribute("aria-selected", String(b.dataset.form === name));
  for (const f of document.querySelectorAll("#sheet form")) f.hidden = f.dataset.form !== name;
}

// A branch name from a prompt: "Fix the flaky login test" -> fix/flaky-login-test.
const PREFIX = { fix: "fix", bug: "fix", repair: "fix", add: "feat", implement: "feat", feat: "feat", build: "feat",
  make: "feat", support: "feat", docs: "docs", document: "docs", refactor: "refactor", test: "test", tests: "test",
  chore: "chore", remove: "chore", update: "chore", bump: "chore" };
const STOP = new Set("the a an to of and in for on with from into that this is are be it its by as at or so".split(" "));

function suggestBranch(prompt) {
  const words = prompt.toLowerCase().match(/[a-z0-9]+/g) || [];
  if (!words.length) return "";
  let prefix = "feat";
  if (PREFIX[words[0]]) prefix = PREFIX[words.shift()];
  const slug = words.filter((w) => !STOP.has(w)).slice(0, 4).join("-").slice(0, 40).replace(/-+$/, "");
  return slug ? prefix + "/" + slug : "";
}

function loadRecent() {
  try {
    const r = JSON.parse(load(RECENT_KEY) || "[]");
    return Array.isArray(r) ? r.filter((x) => typeof x === "string") : [];
  } catch (e) {
    return [];
  }
}

function rememberPrompt(prompt) {
  const p = prompt.trim();
  if (!p) return;
  store(RECENT_KEY, JSON.stringify([p, ...loadRecent().filter((x) => x !== p)].slice(0, RECENT_MAX)));
}

function renderRecent() {
  const list = loadRecent();
  const form = $("f-task");
  $("recent").hidden = !list.length;
  $("recent-list").replaceChildren(
    ...list.map((p) =>
      h("button.recent-item", {
        type: "button",
        title: p,
        onclick: () => {
          form.elements.prompt.value = p;
          onPromptInput();
          form.elements.prompt.focus();
        },
      }, p),
    ),
  );
}

function onPromptInput() {
  const f = $("f-task").elements;
  if (!f.branch.dataset.touched) f.branch.value = suggestBranch(f.prompt.value);
}

async function submitTask(ev) {
  ev.preventDefault();
  const form = ev.target;
  const f = form.elements;
  const body = { repo: f.repo.value, branch: f.branch.value.trim(), persona: f.persona.value, prompt: f.prompt.value };
  remember(body);
  rememberPrompt(body.prompt);
  const { good } = await runWrite([form.querySelector(".go")], "Starting…", form.querySelector(".result"), "/api/start", body, WRITE_WAIT.start);
  if (good) {
    f.prompt.value = "";
    f.branch.value = "";
    delete f.branch.dataset.touched;
  }
  renderRecent();
}

// The task lines of a drafted file, without its comment header.
const taskLines = (text) => (text || "").split("\n").filter((l) => l.trim() && !/^\s*#/.test(l)).join("\n");

function showDrafted(form, file, lines) {
  const box = form.querySelector(".drafted");
  box.hidden = false;
  box.querySelector(".drafted-file").textContent = file;
  box.querySelector(".drafted-text").textContent = lines;
  box.querySelector(".fanout-result").hidden = true;
}

async function submitDraft(ev) {
  ev.preventDefault();
  const form = ev.target;
  const f = form.elements;
  const body = { repo: f.repo.value, goal: f.goal.value };
  remember(body);
  state.drafted = null;
  form.querySelector(".drafted").hidden = true;
  const { res, good } = await runWrite([form.querySelector(".go")], "Drafting… (a minute or two)", form.querySelector(".result"), "/api/draft", body, WRITE_WAIT.draft);
  const d = res.data || {};
  if (!good || !d.file) return;
  state.drafted = { repo: body.repo, file: d.file, hash: d.hash || null };
  showDrafted(form, d.file, taskLines(d.text));
  form.querySelector(".fanout").disabled = !d.hash;
}

// Fans out the last draft with its preview's hash. A stale hash (the file changed) gets a fresh
// preview instead, to look at before tapping again.
async function fanOutDraft() {
  const form = $("f-draft");
  const d = state.drafted;
  if (!d) return;
  const btn = form.querySelector(".fanout");
  const pre = form.querySelector(".fanout-result");
  const { res, good } = await runWrite([btn], "Starting the agents…", pre, "/api/fanout", { repo: d.repo, file: d.file, hash: d.hash }, WRITE_WAIT.fanout);
  if (good) {
    state.drafted = null;
    btn.disabled = true;
    return;
  }
  if (res.status !== 409) return;
  const again = await post("/api/fanout?dry=1", { repo: d.repo, file: d.file }, FETCH_TIMEOUT);
  if (again.ok && again.data.ok && again.data.hash) {
    d.hash = again.data.hash;
    form.querySelector(".drafted-text").textContent = (again.data.output || "").trim();
    pre.textContent = d.file + " changed since its preview. Above is what it would start now; tap Fan out again to start it.";
  }
}

async function submitPlan(ev) {
  ev.preventDefault();
  const form = ev.target;
  const f = form.elements;
  const body = { repo: f.repo.value, branch: f.branch.value.trim(), plan_text: f.plan_text.value, verify: f.verify.value.trim(), persona: f.persona.value };
  remember(body);
  const { good } = await runWrite([form.querySelector(".go")], "Starting…", form.querySelector(".result"), "/api/plan", body, WRITE_WAIT.plan);
  if (good) f.plan_text.value = "";
}

// --- writes: the detail view's buttons ------------------------------------------------------------

function resetActions() {
  $("detail-actions").hidden = !canWrite();
  $("discard-confirm").hidden = true;
  $("discard-word").value = "";
  $("discard-go").disabled = true;
  $("act-result").hidden = true;
}

const actButtons = () => ["act-resume", "act-done", "act-discard", "discard-go"].map($);

async function act(path, extra, busy, timeout) {
  if (!state.detail) return;
  const { repo, branch } = state.detail;
  const body = path === "/api/plan-resume" ? { repo, branch } : { repo, branches: [branch], ...extra };
  await runWrite(actButtons(), busy, $("act-result"), path, body, timeout);
  if (path === "/api/rm") $("discard-confirm").hidden = true;
  $("discard-go").disabled = $("discard-word").value.trim() !== "discard";
}

// --- start --------------------------------------------------------------------------------------

function showPair(error) {
  disconnect();
  state.detail = null;
  $("overview").hidden = true;
  $("detail").hidden = true;
  $("pair").hidden = false;
  $("forget").hidden = !state.token;
  $("host").textContent = "";
  $("counts").textContent = "";
  setConn(false, "not paired");
  const err = $("pair-error");
  err.textContent = error || "";
  err.hidden = !error;
}

async function start() {
  takeTokenFromUrl();
  state.token = load(TOKEN_KEY);
  if (!state.token) return showPair("");
  $("overview").hidden = false;
  $("forget").hidden = false;
  // Connect at once; the config (only needed for the relay links) arrives when it does.
  connect();
  const r = await api("/api/config");
  if (r.status === 401) return showPair("This device's token was not accepted. Pair it again.");
  if (r.ok) {
    setConfig(r.data);
    render();
  }
}

document.addEventListener("DOMContentLoaded", () => {
  $("forget").addEventListener("click", forget);
  $("back").addEventListener("click", () => history.back());
  $("reload").addEventListener("click", () => selectTab(state.tab));
  for (const b of document.querySelectorAll("#detail .tabs [role=tab]")) b.addEventListener("click", () => selectTab(b.dataset.what));
  window.addEventListener("popstate", () => {
    if (!$("sheet").hidden) hideSheet();
    else if (state.detail) closeDetail();
  });
  $("new").addEventListener("click", openSheet);
  $("sheet-close").addEventListener("click", () => history.back());
  for (const b of document.querySelectorAll("#sheet [role=tab]")) b.addEventListener("click", () => selectForm(b.dataset.form));
  for (const sel of document.querySelectorAll(".repo-pick")) sel.addEventListener("change", () => fillPersonas(sel.form));
  $("f-task").addEventListener("submit", submitTask);
  $("f-draft").addEventListener("submit", submitDraft);
  $("f-plan").addEventListener("submit", submitPlan);
  $("f-task").elements.prompt.addEventListener("input", onPromptInput);
  $("f-task").elements.branch.addEventListener("input", (ev) => {
    if (ev.target.value) ev.target.dataset.touched = "1";
    else delete ev.target.dataset.touched;
  });
  $("f-draft").querySelector(".fanout").addEventListener("click", fanOutDraft);
  $("act-resume").addEventListener("click", () => act("/api/plan-resume", null, "Resuming…", WRITE_WAIT.plan));
  $("act-done").addEventListener("click", () => act("/api/done", null, "Checking…", WRITE_WAIT.done));
  $("act-discard").addEventListener("click", () => {
    $("discard-confirm").hidden = false;
    $("discard-word").focus();
  });
  $("discard-word").addEventListener("input", (ev) => ($("discard-go").disabled = ev.target.value.trim() !== "discard"));
  $("discard-go").addEventListener("click", () => {
    if ($("discard-word").value.trim() === "discard") act("/api/rm", { confirm: "discard" }, "Discarding…", WRITE_WAIT.rm);
  });
  // A phone wakes the page up after a long sleep: reconnect now instead of waiting out the backoff.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && state.token && !state.es) {
      state.backoff = BACKOFF_MIN;
      connect();
    }
  });
  window.addEventListener("hashchange", () => {
    if (/(?:^#|&)t=/.test(location.hash)) start();
  });
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
  start();
});
