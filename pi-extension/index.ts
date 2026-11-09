import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { execFile } from "node:child_process";

// Single transport: SSH, key-based, to the Tailscale IP.
// On the server box itself, ssh to the same IP (or 127.0.0.1) with the same key.
const SSH_USER = "bongtangco";
const SSH_HOST = "100.126.215.69";
const FALLBACK_PORTS = [1234, 1235];
const HEALTH_TIMEOUT_MS = 300_000; // matches server-side health wait
const HEALTH_POLL_MS = 2_000;

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
  backend: "radiance" | "llama.cpp";
  vramUsed: number;
  vramTotal: number;
  gpuBusy: number;
  cpuPercent: number;
  ramUsedMb: number;
  ramTotalMb: number;
  hostStatsValid: boolean;
}

function mergeStatus(gpus: GpuStatus[], rad: RadStatus[] | null): ViewEntry[] {
  return gpus.map((g) => {
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

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    ctx.ui.notify(`llamesa loaded · ${SSH_USER}@${SSH_HOST}`, "info");
  });

  pi.registerCommand("llamesa", {
    description: "LLaMesa status + performance snapshot (what's running per GPU, VRAM/GPU/CPU/RAM; modal, Esc to close)",
    handler: async (_args, ctx) => {
      try {
        const [gpus, rad] = await Promise.all([getAllStatus(), getRadStatus()]);
        await statModal(ctx, statLines(mergeStatus(gpus, rad)));
      } catch (err) {
        ctx.ui.notify(`llamesa: ${(err as Error).message}`, "error");
      }
    },
  });

  pi.registerCommand("llamesa-start", startCommand(0, "GPU 0 (R9700A, port 1234)"));
  pi.registerCommand("llamesa-start-2nd", startCommand(1, "GPU 1 (R9700B, port 1235)"));

  pi.registerCommand("llamesa-stop", {
    description: "Stop all LLaMesa instances (both GPUs, both engines)",
    handler: async (_args, ctx) => {
      try {
        await runLlamesa(["stop", "--gpu", "all"], 60_000);
        try {
          await runLlamesa(["stop-rad"], 60_000);
        } catch {
          // no radiance block on the server; stop --gpu all still applied
        }
        const [gpus, rad] = await Promise.all([getAllStatus(), getRadStatus()]);
        for (const line of statusLines(mergeStatus(gpus, rad))) ctx.ui.notify(line, "info");
      } catch (err) {
        ctx.ui.notify(`llamesa-stop: ${(err as Error).message}`, "error");
      }
    },
  });
}
