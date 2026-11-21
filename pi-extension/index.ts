import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

// Single transport: SSH, key-based, to the Tailscale IP.
// On the server box itself, ssh to the same IP (or 127.0.0.1) with the same key.
const SSH_USER = "bongtangco";
const SSH_HOST = "100.126.215.69";
const FALLBACK_PORTS = [1234, 1235];
const HEALTH_TIMEOUT_MS = 300_000; // matches server-side health wait
const HEALTH_POLL_MS = 2_000;
const VIDEO_DIR = join(homedir(), "Videos", "llamesa");
const VIDEO_JOB_TIMEOUT_MS = 15 * 60_000;

// Radiance video server (start-gen) status.
interface GenStatus {
  running: boolean;
  model: string | null;
  gpu: number;
  port: number;
  uptime: string | null;
  vram_used_bytes: number;
  vram_total_bytes: number;
  gpu_busy_percent: number;
}

interface GpuStatus {
  gpu_id: number;
  gpu_name: string;
  running: boolean;
  model: string | null;
  mmproj: boolean;
  thinking: boolean;
  ctx: number;
  port: number;
  uptime: string | null;
  vram_used_bytes: number;
  vram_total_bytes: number;
  gpu_busy_percent: number;
  cpu_percent: number;
  ram_used_mb: number;
  ram_total_mb: number;
}

// Radiance (-rad) instance status. gpu_id is the instance key (r9700a/r9700b).
interface RadStatus {
  gpu_id: string;
  running: boolean;
  model: string | null;
  name: string | null;
  ctx: number;
  port: number;
  uptime: string | null;
  devices: Array<{ id: string; vram_used_bytes: number; vram_total_bytes: number; gpu_busy_percent: number }>;
  thinking: boolean;
  cpu_percent: number;
  ram_used_mb: number;
  ram_total_mb: number;
}

type CommandCtx = Parameters<Parameters<ExtensionAPI["registerCommand"]>[1]["handler"]>[1];

function shellQuote(arg: string): string {
  return `'${arg.replaceAll("'", `'\\''`)}'`;
}

// Run a raw shell command over SSH. stdout and stderr are kept separate.
function runSsh(remote: string, timeoutMs = 30_000): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    execFile(
      "ssh",
      ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", `${SSH_USER}@${SSH_HOST}`, remote],
      { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err && !stdout && !stderr) {
          reject(new Error(stderr.trim().split(/\r?\n/).slice(-3).join(" | ") || err.message));
        } else {
          resolve({ stdout, stderr });
        }
      },
    );
  });
}

// Run one llamesa.sh subcommand over SSH. stdout is JSON only (server contract).
async function runLlamesa(args: string[], timeoutMs = 30_000): Promise<string> {
  const remote = `bash ~/.llamesa/llamesa.sh ${args.map(shellQuote).join(" ")}`;
  const { stdout } = await runSsh(remote, timeoutMs);
  return stdout;
}

// Defensive parse: server stdout is JSON only, but stray lines are tolerated.
// Find the first line that opens an object or array, parse from there.
function extractJson(text: string): unknown {
  const lines = text.split(/\r?\n/);
  const start = lines.findIndex((l) => /^[{\[]/.test(l.trim()));
  if (start === -1) {
    throw new Error(`no JSON in server output: ${text.trim().slice(0, 200) || "(empty)"}`);
  }
  return JSON.parse(lines.slice(start).join("\n"));
}

async function getAllStatus(): Promise<GpuStatus[]> {
  const out = await runLlamesa(["status", "--gpu", "all"]);
  const parsed = extractJson(out);
  if (!Array.isArray(parsed)) throw new Error("status --gpu all did not return an array");
  return parsed as GpuStatus[];
}

// Radiance status. Null when the server has no radiance block (command errors).
async function getRadStatus(): Promise<RadStatus[] | null> {
  try {
    const out = await runLlamesa(["status-rad"]);
    const parsed = extractJson(out);
    const arr = Array.isArray(parsed) ? parsed : [parsed];
    return arr as RadStatus[];
  } catch {
    return null;
  }
}

// Video server status. Null when the server has no radiance.gen block.
async function getGenStatus(): Promise<GenStatus | null> {
  try {
    const out = await runLlamesa(["status-gen"]);
    return extractJson(out) as GenStatus;
  } catch {
    return null;
  }
}

// Ports from the server config, cached per session. One short SSH call.
let portsCache: number[] | null = null;
async function getPorts(): Promise<number[]> {
  if (portsCache) return portsCache;
  try {
    const { stdout } = await runSsh("cat ~/.llamesa/config.json");
    const cfg = JSON.parse(stdout);
    const ports: number[] = [];
    for (const g of cfg.gpus ?? []) if (typeof g.port === "number") ports.push(g.port);
    portsCache = ports.length >= 2 ? ports : FALLBACK_PORTS;
  } catch {
    portsCache = FALLBACK_PORTS;
  }
  return portsCache;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Any 2xx on /health counts. llama-server answers {"status":"ok"}; Radiance
// answers 200 with its own body. The server's own checks are HTTP-success only.
async function healthOk(port: number): Promise<boolean> {
  try {
    const res = await fetch(`http://${SSH_HOST}:${port}/health`, { signal: AbortSignal.timeout(3_000) });
    return res.ok;
  } catch {
    return false;
  }
}

// Model list. Radiance models first (the primary engine); falls back to the
// llama.cpp .gguf list when the server has no radiance block.
interface ModelEntry {
  name: string;
  context_length?: number | null;
  path?: string;
}
async function listStartModels(): Promise<{ entries: ModelEntry[]; backend: "radiance" | "gguf" }> {
  try {
    const out = await runLlamesa(["list-models-rad"]);
    const parsed = extractJson(out);
    const entries = (Array.isArray(parsed) ? parsed : []) as ModelEntry[];
    if (entries.length > 0) return { entries, backend: "radiance" };
  } catch {
    // no radiance block on the server
  }
  const out = await runLlamesa(["list-models"]);
  const parsed = extractJson(out);
  if (!Array.isArray(parsed)) throw new Error("list-models did not return an array");
  return { entries: parsed as ModelEntry[], backend: "gguf" };
}

// The model's native max context. Radiance: context_length from list-models-rad
// (the server's RAD_DEFAULT_CTX, equal to the served max_model_len).
// llama.cpp fallback: model-context reads the GGUF header.
async function modelMaxContext(entry: ModelEntry, backend: "radiance" | "gguf"): Promise<number | undefined> {
  if (typeof entry.context_length === "number") return entry.context_length;
  if (backend === "gguf" && entry.path) {
    try {
      const out = await runLlamesa(["model-context", "--path", entry.path]);
      const parsed = extractJson(out) as { context_length?: number | null };
      if (typeof parsed.context_length === "number") return parsed.context_length;
    } catch {
      // best effort; blank stays blank (server default applies)
    }
  }
  return undefined;
}

// Model list cache for argument autocompletion (5 minute TTL).
let modelCache: { at: number; names: string[] } | null = null;
async function cachedModelNames(): Promise<string[]> {
  if (modelCache && Date.now() - modelCache.at < 5 * 60_000) return modelCache.names;
  const { entries } = await listStartModels();
  modelCache = { at: Date.now(), names: entries.map((e) => e.name) };
  return modelCache.names;
}

interface StartOptions {
  thinking: "on" | "off";
  ctx: number | null; // null = leave to server default
  parallel: number | null; // null = leave to server default (flag omitted)
}

// The three settings the user asked to be prompted for, after the model.
async function askStartOptions(ctx: CommandCtx, model: ModelEntry, backend: "radiance" | "gguf"): Promise<StartOptions> {
  if (ctx.mode !== "tui") {
    // Non-interactive: server defaults (thinking on, model max ctx, 8 seqs)
    const maxCtx = await modelMaxContext(model, backend);
    return { thinking: "on", ctx: maxCtx ?? null, parallel: null };
  }
  const thinking = (await ctx.ui.select("Thinking mode", ["on", "off"])) === "off" ? "off" : "on";
  const maxCtx = await modelMaxContext(model, backend);
  const ctxRaw = await ctx.ui.input(
    "Context size",
    maxCtx ? `blank = model max (${maxCtx})` : "blank = server default",
  );
  let ctxVal: number | null = null;
  if (ctxRaw && ctxRaw.trim()) {
    const n = Number(ctxRaw.trim());
    if (!Number.isInteger(n) || n <= 0) throw new Error(`invalid context size: ${ctxRaw}`);
    ctxVal = n;
  } else if (maxCtx) {
    ctxVal = maxCtx;
  }
  const parRaw = (await ctx.ui.input("Parallel sequences?", "[1-32, Enter for the server default]:"))?.trim();
  let parallel: number | null = null;
  if (parRaw) {
    const n = Number(parRaw);
    if (!Number.isInteger(n) || n < 1 || n > 32) throw new Error(`invalid parallel value: ${parRaw} (expected 1-32)`);
    parallel = n;
  }
  return { thinking, ctx: ctxVal, parallel };
}

const gb = (bytes: number) => (bytes / 1073741824).toFixed(1);

function formatUptime(uptime: string | null): string {
  if (!uptime) return "00:00:00";
  const [h, m] = uptime.split(":");
  return `${Number(h)}h ${Number(m)}m`;
}

// One view entry per GPU port. The running backend (radiance or llama.cpp)
// wins; both are never running on the same port.
interface ViewEntry {
  gpuId: number;
  name: string;
  port: number;
  running: boolean;
  model: string | null;
  uptime: string | null;
  backend: "radiance" | "llama.cpp" | "radiance video";
  vramUsed: number;
  vramTotal: number;
  gpuBusy: number;
  cpuPercent: number;
  ramUsedMb: number;
  ramTotalMb: number;
  hostStatsValid: boolean;
}

function mergeStatus(gpus: GpuStatus[], rad: RadStatus[] | null, gen: GenStatus | null = null): ViewEntry[] {
  return gpus.map((g) => {
    // The video server takes a whole GPU; when it runs there it wins the view.
    if (gen?.running && gen.gpu === g.gpu_id) {
      return {
        gpuId: g.gpu_id, name: g.gpu_name, port: gen.port, running: true,
        model: gen.model, uptime: gen.uptime, backend: "radiance video",
        vramUsed: g.vram_used_bytes, vramTotal: g.vram_total_bytes,
        gpuBusy: gen.gpu_busy_percent, cpuPercent: 0, ramUsedMb: 0, ramTotalMb: 0,
        hostStatsValid: false,
      };
    }
    const r = rad?.find((x) => x.port === g.port);
    const radUp = r?.running === true;
    const up = radUp || g.running;
    return {
      gpuId: g.gpu_id,
      name: g.gpu_name,
      port: g.port,
      running: up,
      model: radUp ? (r!.model ?? r!.name) : g.running ? g.model : null,
      uptime: radUp ? r!.uptime : g.running ? g.uptime : null,
      backend: radUp ? "radiance" : "llama.cpp",
      // VRAM and GPU busy are per-card sysfs values: valid for either backend.
      vramUsed: g.vram_used_bytes,
      vramTotal: g.vram_total_bytes,
      gpuBusy: r?.devices[0]?.gpu_busy_percent ?? g.gpu_busy_percent,
      // Host stats: radiance fills them when its instance runs; llama.cpp
      // fills them when its server runs. Otherwise they are zeros.
      cpuPercent: radUp ? r!.cpu_percent : g.running ? g.cpu_percent : 0,
      ramUsedMb: radUp ? r!.ram_used_mb : g.running ? g.ram_used_mb : 0,
      ramTotalMb: radUp ? r!.ram_total_mb : g.running ? g.ram_total_mb : 0,
      hostStatsValid: radUp || g.running,
    };
  });
}

function statusLines(view: ViewEntry[]): string[] {
  return view.map((v) =>
    v.running
      ? `GPU ${v.gpuId} (${v.name}) port ${v.port}: running ${v.model ?? "unknown"} via ${v.backend} · up ${formatUptime(v.uptime)}`
      : `GPU ${v.gpuId} (${v.name}) port ${v.port}: stopped`,
  );
}

function statLines(view: ViewEntry[]): string[] {
  const lines: string[] = ["LLaMesa — status & performance"];
  for (const v of view) {
    const vramPct = v.vramTotal > 0 ? Math.round((v.vramUsed / v.vramTotal) * 100) : 0;
    lines.push("");
    lines.push(
      v.running
        ? `GPU ${v.gpuId} (${v.name})  port ${v.port}  ${v.model ?? "unknown"}  [${v.backend}]  up ${formatUptime(v.uptime)}`
        : `GPU ${v.gpuId} (${v.name})  port ${v.port}  stopped`,
    );
    lines.push(`  VRAM   ${gb(v.vramUsed)} / ${gb(v.vramTotal)} GB   ${vramPct}%`);
    lines.push(`  GPU    ${v.gpuBusy}% ${v.gpuBusy > 0 ? "(busy)" : "(idle)"}`);
    lines.push(v.hostStatsValid
      ? `  CPU    ${v.cpuPercent}%  (host)   RAM  ${(v.ramUsedMb / 1024).toFixed(1)} / ${(v.ramTotalMb / 1024).toFixed(1)} GB`
      : "  CPU/RAM  n/a (no instance running)");
  }
  return lines;
}

// Show a bordered, shadowed, centered modal. The TUI centers the overlay block,
// so the box is built at its natural width.
function statModal(ctx: CommandCtx, lines: string[]) {
  if (ctx.mode !== "tui") {
    for (const line of lines) ctx.ui.notify(line, "info");
    return;
  }
  return ctx.ui.custom(
    (_tui, theme, keybindings, done) => {
      const b = (s: string) => theme.fg("border", s);
      const dim = (s: string) => theme.fg("dim", s);
      const content = [
        theme.fg("accent", lines[0]),
        ...lines.slice(1),
        dim("Esc to close"),
      ];
      const innerW = Math.min(
        Math.max(...content.map((l) => visibleWidth(l)), 20) + 2,
        72,
      );
      const row = (s: string) => {
        const truncated = truncateToWidth(s, innerW - 2);
        const pad = innerW - 2 - visibleWidth(truncated);
        return b("│") + " " + truncated + " ".repeat(Math.max(0, pad)) + " " + b("│") + dim("▐");
      };
      const top = b("┌") + b("─".repeat(innerW)) + b("┐") + dim(" ");
      const bot = b("└") + b("─".repeat(innerW)) + b("┘") + dim(" ");
      const shadow = "  " + dim("▀".repeat(innerW + 1));
      return {
        render(_width: number): string[] {
          return [top, ...content.map(row), bot, shadow];
        },
        handleInput(data: string): void {
          if (keybindings.matches(data, "tui.select.cancel") || data === "\u001b") done();
        },
        invalidate() {},
      };
    },
    { overlay: true, overlayOptions: { anchor: "center", margin: 2 } },
  );
}

// Resolve the model for a start command: explicit arg wins (validated with a
// warning), otherwise a picker. Returns the entry (carries max context/path).
async function pickModel(ctx: CommandCtx, gpuLabel: string, arg: string | undefined): Promise<{ entry: ModelEntry; backend: "radiance" | "gguf" }> {
  const { entries, backend } = await listStartModels();
  if (arg) {
    const entry = entries.find((e) => e.name === arg);
    if (!entry) {
      ctx.ui.notify(`warning: "${arg}" not in the model list; trying as given`, "warning");
      return { entry: { name: arg }, backend };
    }
    return { entry, backend };
  }
  if (ctx.mode !== "tui") {
    throw new Error("model argument required: /llamesa-start <model>");
  }
  if (entries.length === 0) throw new Error("no models available");
  const choice = await ctx.ui.select(`Start ${gpuLabel} — pick model`, entries.map((e) => e.name));
  if (!choice) throw new Error("cancelled");
  return { entry: entries.find((e) => e.name === choice)!, backend };
}

// Fire-and-forget start + HTTP health poll (proven client pattern: never hold
// SSH open across a model load; start-rad itself would block up to 300 s).
async function startGpu(ctx: CommandCtx, gpuId: number, model: ModelEntry, backend: "radiance" | "gguf", opts: StartOptions): Promise<void> {
  const ports = await getPorts();
  const port = ports[gpuId] ?? FALLBACK_PORTS[gpuId];
  const [gpus, rad] = await Promise.all([getAllStatus(), getRadStatus()]);
  const current = gpus.find((g) => g.gpu_id === gpuId);
  const radOnPort = rad?.find((r) => r.port === port && r.running);
  const blocker = radOnPort ?? (current?.running ? current : null);
  if (blocker) {
    const what = radOnPort ? `${radOnPort.model ?? "unknown"} (radiance)` : `${current!.model ?? "unknown"} (llama.cpp)`;
    const ok = await ctx.ui.confirm(`GPU ${gpuId} is running ${what} on port ${port}`, "Stop it and start the new session?");
    if (!ok) throw new Error("cancelled");
    if (radOnPort) await runLlamesa(["stop-rad", "--gpu", radOnPort.gpu_id], 60_000);
    else await runLlamesa(["stop", "--gpu", String(gpuId)], 60_000);
    await sleep(3_000);
  }

  let remote: string;
  let logFile: string;
  if (backend === "radiance" || rad) {
    // Radiance is the primary engine: one TP1 podman container per GPU.
    const inst = rad?.find((r) => r.port === port);
    const key = inst?.gpu_id ?? `r9700${gpuId === 1 ? "b" : "a"}`;
    logFile = `~/.llamesa/pistart-${key}.log`;
    const args = [`start-rad`, `--gpu`, key, `--model`, model.name, `--thinking`, opts.thinking];
    if (opts.ctx) args.push(`--ctx`, String(opts.ctx));
    if (opts.parallel !== null) args.push(`--parallel`, String(opts.parallel));
    remote = `bash ~/.llamesa/llamesa.sh ${args.map(shellQuote).join(" ")} >> ${logFile} 2>&1`;
  } else {
    logFile = `~/.llamesa/pistart-gpu${gpuId}.log`;
    const args = [`start`, `--gpu`, String(gpuId), `--model`, model.name, `--thinking`, opts.thinking];
    if (opts.ctx) args.push(`--ctx`, String(opts.ctx));
    if (opts.parallel !== null) {
      const parallel = Math.min(opts.parallel, 4);
      if (parallel < opts.parallel) ctx.ui.notify(`warning: llama.cpp caps --parallel at 4; using ${parallel}`, "warning");
      args.push(`--parallel`, String(parallel));
    }
    remote = `bash ~/.llamesa/llamesa.sh ${args.map(shellQuote).join(" ")} >> ${logFile} 2>&1`;
  }
  // The remote command runs start-rad SYNCHRONOUSLY (no nohup, no &). The
  // background-job variant dies the moment the SSH session closes (SIGHUP) —
  // verified live: the job only survives while the session is held open. Holding
  // the session for the whole start-rad window is exactly what the proven client
  // app does while it polls HTTP in parallel. The SSH child is deliberately not
  // awaited: it runs alongside the /health polling below and exits on its own
  // when start-rad finishes (or dies with pi if pi exits).
  void runSsh(remote, 600_000).catch(() => {});
  ctx.ui.notify(`start fired on GPU ${gpuId} (log: ${logFile})`, "info");

  const startedAt = Date.now();
  ctx.ui.setStatus("llamesa", `starting ${model.name} on GPU ${gpuId} … 0s`);
  try {
    // One early log check: a bad model name or the RAM safety guard fail the
    // start in seconds instead of after the full health window.
    await sleep(8_000);
    try {
      const { stdout } = await runSsh(`tail -n 20 ${logFile}`, 10_000);
      const errLine = stdout.split(/\r?\n/).find((l) => l.includes("[ERROR]"));
      if (errLine) throw new Error(errLine.trim());
    } catch (err) {
      if (err instanceof Error && err.message.includes("[ERROR]")) throw err;
      // log not readable yet; keep polling
    }
    ctx.ui.notify("model loading: polling /health every 2s (up to 300s)", "info");

    const deadline = Date.now() + HEALTH_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await sleep(HEALTH_POLL_MS);
      const elapsed = Math.round((Date.now() - startedAt) / 1000);
      ctx.ui.setStatus("llamesa", `starting ${model.name} on GPU ${gpuId} … ${elapsed}s`);
      if (await healthOk(port)) {
        ctx.ui.notify(`GPU ${gpuId}: running ${model.name} on port ${port} (thinking ${opts.thinking}, ctx ${opts.ctx ?? "server default"}, parallel ${opts.parallel ?? "server default"})`, "info");
        return;
      }
    }
    throw new Error(`health timeout after ${HEALTH_TIMEOUT_MS / 1000}s. Check: tail -f ${logFile}`);
  } finally {
    ctx.ui.setStatus("llamesa", undefined);
  }
}

function startCommand(gpuId: number, label: string) {
  return {
    description: `Start LLaMesa on ${label} (model arg or picker)`,
    getArgumentCompletions: async (prefix: string) => {
      try {
        const names = await cachedModelNames();
        const filtered = names.filter((n) => n.toLowerCase().startsWith(prefix.toLowerCase()));
        return filtered.length > 0 ? filtered.map((n) => ({ value: n, label: n })) : null;
      } catch {
        return null;
      }
    },
    handler: async (args: string, ctx: CommandCtx) => {
      try {
        ctx.ui.setStatus("llamesa", "llamesa-start: fetching model list …");
        const { entry, backend } = await pickModel(ctx, label, args);
        ctx.ui.setStatus("llamesa", undefined);
        ctx.ui.notify(`model: ${entry.name}`, "info");
        const opts = await askStartOptions(ctx, entry, backend);
        ctx.ui.notify(
          `options: thinking ${opts.thinking}, ctx ${opts.ctx ?? "server default"}, parallel ${opts.parallel ?? "server default"}`,
          "info",
        );
        ctx.ui.setStatus("llamesa", "llamesa-start: checking status …");
        await startGpu(ctx, gpuId, entry, backend, opts);
      } catch (err) {
        ctx.ui.setStatus("llamesa", undefined);
        const msg = (err as Error).message;
        ctx.ui.notify(msg === "cancelled" ? "llamesa-start: cancelled" : `llamesa-start: ${msg}`, msg === "cancelled" ? "info" : "error");
      }
    },
  };
}

// ── Video generation (Radiance video server, start-gen) ──────────────────

const VIDEO_SIZES: Array<{ label: string; size: string }> = [
  { label: "960x544 landscape (about 22 s for 5 s of video)", size: "960x544" },
  { label: "1280x704 landscape (about 42 s)", size: "1280x704" },
  { label: "544x960 portrait", size: "544x960" },
  { label: "704x1280 portrait", size: "704x1280" },
  { label: "768x768 square", size: "768x768" },
];
const VIDEO_LENGTHS: Array<{ label: string; seconds: string | null }> = [
  { label: "auto (the model picks from the prompt)", seconds: null },
  { label: "3 s", seconds: "3" },
  { label: "5 s", seconds: "5" },
  { label: "6.7 s (the longest it makes)", seconds: "6.7" },
];

interface VideoOptions {
  size: string;
  seconds: string | null;
  seed: number;
  expand: boolean;
}

// A running Radiance chat instance to write the prompt with (first healthy one).
async function findChatPort(): Promise<{ port: number; model: string } | null> {
  const rad = await getRadStatus();
  for (const r of rad ?? []) {
    if (!r.running) continue;
    try {
      const res = await fetch(`http://${SSH_HOST}:${r.port}/v1/models`, { signal: AbortSignal.timeout(5_000) });
      const j = (await res.json()) as { data?: Array<{ id: string }> };
      const id = j.data?.[0]?.id;
      if (id) return { port: r.port, model: id };
    } catch {
      // try the next instance
    }
  }
  return null;
}

// LTX-2.5 was trained on long single-paragraph captions; short prompts give
// generic results. Ask the chat model to write one from the user's idea.
async function expandVideoPrompt(chat: { port: number; model: string }, idea: string): Promise<string> {
  const system =
    "You write prompts for a text-to-video model that also generates the soundtrack. " +
    "Rewrite the user's idea as ONE paragraph of 80 to 140 words describing: the subject and setting, " +
    "the motion and action over a few seconds, the camera shot and movement, the light and colour, " +
    "and the sounds heard. Concrete visual language, present tense, no lists, no title, no quotes, " +
    "no text overlays unless asked. Output only the paragraph.";
  const res = await fetch(`http://${SSH_HOST}:${chat.port}/v1/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      model: chat.model,
      messages: [{ role: "system", content: system }, { role: "user", content: idea }],
      max_tokens: 400,
      temperature: 0.7,
      chat_template_kwargs: { enable_thinking: false },
    }),
    signal: AbortSignal.timeout(120_000),
  });
  if (!res.ok) throw new Error(`prompt writer HTTP ${res.status}`);
  const j = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
  const text = j.choices?.[0]?.message?.content?.trim();
  if (!text) throw new Error("prompt writer returned nothing");
  return text.replace(/^["']|["']$/g, "");
}

// Make sure the video server runs. Starting it may need the chat instance on
// its GPU stopped first: always asked, never done silently.
async function ensureGenServer(ctx: CommandCtx): Promise<number> {
  const gen = await getGenStatus();
  if (!gen) throw new Error("the server has no radiance.gen block (video server not configured)");
  if (gen.running) return gen.port;
  const rad = await getRadStatus();
  const radKey = gen.gpu === 1 ? "r9700b" : "r9700a";
  const blocker = rad?.find((r) => r.gpu_id === radKey && r.running);
  if (ctx.mode !== "tui" && blocker) {
    throw new Error(`GPU ${gen.gpu} is running ${blocker.model ?? "a chat model"}; stop it first`);
  }
  if (ctx.mode === "tui") {
    const msg = blocker
      ? `This stops ${blocker.model ?? "the chat model"} on GPU ${gen.gpu} (port ${blocker.port}) and starts the video server there.`
      : `Start the video server on GPU ${gen.gpu} (port ${gen.port})? It takes about 15 s.`;
    const ok = await ctx.ui.confirm("Video server is not running", msg);
    if (!ok) throw new Error("cancelled");
  }
  if (blocker) {
    await runLlamesa(["stop-rad", "--gpu", blocker.gpu_id], 60_000);
    await sleep(3_000);
  }
  const logFile = "~/.llamesa/pistart-gen.log";
  // Synchronous on the server, not awaited here (same pattern as startGpu).
  void runSsh(`bash ~/.llamesa/llamesa.sh start-gen >> ${logFile} 2>&1`, 600_000).catch(() => {});
  const startedAt = Date.now();
  try {
    await sleep(6_000);
    try {
      const { stdout } = await runSsh(`tail -n 20 ${logFile}`, 10_000);
      const errLine = stdout.split(/\r?\n/).find((l) => l.includes("[ERROR]"));
      if (errLine) throw new Error(errLine.trim());
    } catch (err) {
      if (err instanceof Error && err.message.includes("[ERROR]")) throw err;
    }
    while (Date.now() - startedAt < HEALTH_TIMEOUT_MS) {
      ctx.ui.setStatus("llamesa", `starting video server on GPU ${gen.gpu} … ${Math.round((Date.now() - startedAt) / 1000)}s`);
      if (await healthOk(gen.port)) {
        ctx.ui.notify(`video server ready on GPU ${gen.gpu}, port ${gen.port}`, "info");
        return gen.port;
      }
      await sleep(HEALTH_POLL_MS);
    }
    throw new Error(`video server did not come up in ${HEALTH_TIMEOUT_MS / 1000}s. Check: tail -f ${logFile}`);
  } finally {
    ctx.ui.setStatus("llamesa", undefined);
  }
}

function videoFileBase(idea: string): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  const stamp = `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  const slug = idea.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "video";
  return `${stamp}-${slug}`;
}

// Queue one video, poll it with a live status line, save MP4 + prompt locally.
async function generateVideo(ctx: CommandCtx, port: number, prompt: string, idea: string, opts: VideoOptions): Promise<string> {
  const base = `http://${SSH_HOST}:${port}/v1/videos`;
  const body: Record<string, unknown> = { prompt, size: opts.size, seed: opts.seed };
  if (opts.seconds) body.seconds = opts.seconds;
  const res = await fetch(base, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(60_000),
  });
  const job = (await res.json()) as { id?: string; status?: string; error?: { message?: string } | null };
  if (!res.ok || !job.id) throw new Error(job.error?.message ?? `video request HTTP ${res.status}`);
  const startedAt = Date.now();
  let last: Record<string, unknown> = job as Record<string, unknown>;
  try {
    while (true) {
      const status = String(last.status ?? "");
      if (status === "completed") break;
      if (status === "failed" || status === "cancelled") {
        const e = last.error as { message?: string } | null;
        throw new Error(`video ${status}: ${e?.message ?? "no reason given"}`);
      }
      if (Date.now() - startedAt > VIDEO_JOB_TIMEOUT_MS) throw new Error("video job timed out after 15 min");
      const secs = Math.round((Date.now() - startedAt) / 1000);
      const steps = last.steps_total ? ` step ${last.steps_done ?? 0}/${last.steps_total}` : "";
      ctx.ui.setStatus("llamesa", `video ${status || "queued"}${steps} · ${last.progress ?? 0}% · ${secs}s`);
      await sleep(1_500);
      const r = await fetch(`${base}/${job.id}`, { signal: AbortSignal.timeout(15_000) });
      last = (await r.json()) as Record<string, unknown>;
    }
    ctx.ui.setStatus("llamesa", "video done · downloading …");
    const mp4 = await fetch(`${base}/${job.id}/content`, { signal: AbortSignal.timeout(300_000) });
    if (!mp4.ok) throw new Error(`download HTTP ${mp4.status}`);
    const bytes = Buffer.from(await mp4.arrayBuffer());
    await mkdir(VIDEO_DIR, { recursive: true });
    const fileBase = join(VIDEO_DIR, videoFileBase(idea));
    await writeFile(`${fileBase}.mp4`, bytes);
    await writeFile(
      `${fileBase}.txt`,
      `idea: ${idea}\nprompt: ${prompt}\nsize: ${opts.size}\nseconds: ${last.seconds ?? opts.seconds ?? "auto"}\nseed: ${opts.seed}\nmodel: ${last.model ?? ""}\nmade in: ${Math.round((Date.now() - startedAt) / 1000)} s\n`,
    );
    return `${fileBase}.mp4`;
  } finally {
    ctx.ui.setStatus("llamesa", undefined);
  }
}

async function askVideoOptions(ctx: CommandCtx, chatAvailable: boolean): Promise<VideoOptions> {
  const seed = Math.floor(Math.random() * 2 ** 31);
  if (ctx.mode !== "tui") return { size: "960x544", seconds: null, seed, expand: chatAvailable };
  const sizeLabel = await ctx.ui.select("Video size", VIDEO_SIZES.map((s) => s.label));
  if (!sizeLabel) throw new Error("cancelled");
  const lenLabel = await ctx.ui.select("Length", VIDEO_LENGTHS.map((l) => l.label));
  if (!lenLabel) throw new Error("cancelled");
  let expand = false;
  if (chatAvailable) {
    const e = await ctx.ui.select("Let Qwen write the detailed prompt? (LTX works best with a long description)", [
      "yes, expand my idea",
      "no, use my text as is",
    ]);
    if (!e) throw new Error("cancelled");
    expand = e.startsWith("yes");
  }
  return {
    size: VIDEO_SIZES.find((s) => s.label === sizeLabel)!.size,
    seconds: VIDEO_LENGTHS.find((l) => l.label === lenLabel)!.seconds,
    seed,
    expand,
  };
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.notify(`llamesa loaded · ${SSH_USER}@${SSH_HOST}`, "info");
  });

  pi.registerCommand("llamesa", {
    description: "LLaMesa status + performance snapshot (what's running per GPU, VRAM/GPU/CPU/RAM; modal, Esc to close)",
    handler: async (_args, ctx) => {
      try {
        const [gpus, rad, gen] = await Promise.all([getAllStatus(), getRadStatus(), getGenStatus()]);
        await statModal(ctx, statLines(mergeStatus(gpus, rad, gen)));
      } catch (err) {
        ctx.ui.notify(`llamesa: ${(err as Error).message}`, "error");
      }
    },
  });

  pi.registerCommand("llamesa-start", startCommand(0, "GPU 0 (R9700A, port 1234)"));
  pi.registerCommand("llamesa-start-2nd", startCommand(1, "GPU 1 (R9700B, port 1235)"));

  pi.registerCommand("llamesa-stop", {
    description: "Stop all LLaMesa instances (both GPUs, all engines, the video server too)",
    handler: async (_args, ctx) => {
      try {
        await runLlamesa(["stop", "--gpu", "all"], 60_000);
        try {
          await runLlamesa(["stop-rad"], 60_000);
        } catch {
          // no radiance block on the server; stop --gpu all still applied
        }
        try {
          await runLlamesa(["stop-gen"], 60_000);
        } catch {
          // no radiance.gen block on the server
        }
        const [gpus, rad, gen] = await Promise.all([getAllStatus(), getRadStatus(), getGenStatus()]);
        for (const line of statusLines(mergeStatus(gpus, rad, gen))) ctx.ui.notify(line, "info");
      } catch (err) {
        ctx.ui.notify(`llamesa-stop: ${(err as Error).message}`, "error");
      }
    },
  });

  pi.registerCommand("llamesa-video", {
    description: `Make a short video with sound on the Radiance video server (describe it; saved to ${VIDEO_DIR})`,
    handler: async (args: string, ctx: CommandCtx) => {
      try {
        let idea = args.trim();
        if (!idea) {
          if (ctx.mode !== "tui") throw new Error("describe the video: /llamesa-video <description>");
          idea = ((await ctx.ui.input("Describe the video", "a shot, what moves, the mood, any sound")) ?? "").trim();
          if (!idea) throw new Error("cancelled");
        }
        ctx.ui.setStatus("llamesa", "llamesa-video: checking servers …");
        const chat = await findChatPort();
        ctx.ui.setStatus("llamesa", undefined);
        const opts = await askVideoOptions(ctx, chat !== null);
        let prompt = idea;
        if (opts.expand && chat) {
          ctx.ui.setStatus("llamesa", "llamesa-video: Qwen is writing the prompt …");
          prompt = await expandVideoPrompt(chat, idea);
          ctx.ui.setStatus("llamesa", undefined);
          ctx.ui.notify(`prompt: ${prompt}`, "info");
          if (ctx.mode === "tui") {
            const use = await ctx.ui.select("Use this prompt?", ["yes, make the video", "no, use my original text", "cancel"]);
            if (!use || use === "cancel") throw new Error("cancelled");
            if (use.startsWith("no")) prompt = idea;
          }
        }
        const port = await ensureGenServer(ctx);
        ctx.ui.notify(`making video: ${opts.size}, ${opts.seconds ? `${opts.seconds} s` : "auto length"}, seed ${opts.seed}`, "info");
        const file = await generateVideo(ctx, port, prompt, idea, opts);
        ctx.ui.notify(`video saved: ${file} (prompt and seed in the .txt beside it)`, "info");
      } catch (err) {
        ctx.ui.setStatus("llamesa", undefined);
        const msg = (err as Error).message;
        ctx.ui.notify(msg === "cancelled" ? "llamesa-video: cancelled" : `llamesa-video: ${msg}`, msg === "cancelled" ? "info" : "error");
      }
    },
  });

  pi.registerCommand("llamesa-video-stop", {
    description: "Stop the Radiance video server (frees its GPU for chat)",
    handler: async (_args, ctx) => {
      try {
        await runLlamesa(["stop-gen"], 60_000);
        ctx.ui.notify("video server stopped", "info");
      } catch (err) {
        ctx.ui.notify(`llamesa-video-stop: ${(err as Error).message}`, "error");
      }
    },
  });
}
