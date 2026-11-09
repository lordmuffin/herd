// Pure helpers for the herd mod: no host calls, so they run anywhere.

// The mod's own folder name, used for its assets and its <mod>.<command>s.
export const MOD = "herd";

// Most urgent first, as the app ranks a space's agents.
const RANK = { blocked: 4, done: 3, working: 2, idle: 1 };
export const urgent = (list) => list.filter((s) => s in RANK).sort((a, b) => RANK[b] - RANK[a])[0] ?? null;

// `herd status -j`: one JSON object per line.
export function parseStreams(stdout) {
  return (stdout ?? "")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.startsWith("{"))
    .map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter(Boolean);
}

// A stream's status: the app's live one for its space, else what herd read from hc.
export function streamStatus(stream, agentList) {
  const live = urgent(agentList.filter((a) => a.space === stream.workspace).map((a) => a.status));
  if (live) return live;
  return stream.status && stream.status !== "-" ? stream.status : null;
}

// The line under a stream's branch: its plan stage, else its agent's status.
export function streamDetail(stream, status) {
  const parts = [];
  if (stream.plan) parts.push(stream.plan);
  parts.push(status ?? (stream.workspace && stream.workspace !== "-" ? "no agent" : "no space open"));
  return parts.join(" · ");
}

// Streams needing the person first, then working ones, then the rest, each by branch.
export function sortStreams(rows) {
  return [...rows].sort((a, b) => (RANK[b.status] ?? 0) - (RANK[a.status] ?? 0) || a.branch.localeCompare(b.branch));
}

// The repo's main checkout from git's common dir ("/x/repo/.git" -> "/x/repo").
export const mainCheckout = (commonDir) => commonDir.trim().replace(/\/\.git\/?$/, "");
export const baseName = (path) => path.replace(/\/+$/, "").split("/").pop();

// "Tasks.herd" when free, else a dated name, as herd draft wants.
export function draftName(existing, now = new Date()) {
  if (!existing.includes("Tasks.herd")) return "Tasks.herd";
  const pad = (n) => String(n).padStart(2, "0");
  return `Tasks-${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}.herd`;
}

// A command value carrying data: "<mod>.<name>:<json>". Only the value reaches nextCommand.
export const encode = (name, data) => `${MOD}.${name}:${JSON.stringify(data)}`;
export function decode(command) {
  const at = command.indexOf(":");
  if (at < 0) return { name: command, data: null };
  const raw = command.slice(at + 1);
  try { return { name: command.slice(0, at), data: JSON.parse(raw) }; } catch { return { name: command.slice(0, at), data: raw }; }
}

// The last non-blank lines of a job's output, for a one-line summary.
export const lastLine = (text) => (text ?? "").split("\n").map((l) => l.trim()).filter(Boolean).pop() ?? "";
