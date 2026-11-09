const { spawn, execFile } = require("child_process");
const fs = require("fs");

const LOG = "C:/Development/llamesa/pi-extension/last-run.txt";
const out = (s) => console.log(s);

fs.writeFileSync(LOG, "");

const pi = spawn("pi", ["--mode", "rpc"], {
  cwd: "C:/Development",
  stdio: ["pipe", "pipe", "pipe"],
  env: { ...process.env },
  shell: true,
});

pi.stderr.on("data", (d) => out("[pi-err] " + d.toString().trim().slice(0, 300)));

let buf = "";
pi.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) !== -1) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { out("[pi-raw] " + line.slice(0, 200)); continue; }

    if (ev.type === "response" && ev.command === "prompt") {
      out("[prompt-response] success=" + ev.success + " disposition=" + (ev.data && ev.data.disposition));
    }

    // Extension UI sub-protocol: respond to dialog methods so the extension
    // flow can proceed (confirm -> yes, select -> first option, input -> "").
    if (ev.type === "extension_ui_request") {
      out("[ui-request] " + ev.method + " " + (ev.title || "") + " " + (ev.message || "").slice(0, 60) + " opts=" + JSON.stringify(ev.options || []).slice(0, 120));
      if (ev.method === "confirm") {
        pi.stdin.write(JSON.stringify({ type: "extension_ui_response", id: ev.id, confirmed: true }) + "\n");
      } else if (ev.method === "select") {
        const first = (ev.options && ev.options[0]) || "";
        pi.stdin.write(JSON.stringify({ type: "extension_ui_response", id: ev.id, value: first }) + "\n");
      } else if (ev.method === "input" || ev.method === "editor") {
        pi.stdin.write(JSON.stringify({ type: "extension_ui_response", id: ev.id, value: "" }) + "\n");
      }
    }
  }
});

setTimeout(() => {
  out("[sending prompt] /llamesa-start-2nd qwen3.8-27b-mxfp4");
  pi.stdin.write(JSON.stringify({ id: "req-1", type: "prompt", message: "/llamesa-start-2nd qwen3.8-27b-mxfp4" }) + "\n");
}, 12000);

function health() {
  return new Promise((res) => {
    // No -o /dev/null: on Windows that path doesn't exist, curl exits 23
    // AFTER a successful transfer, which read as a false failure.
    execFile("curl", ["-s", "-w", "%{http_code}\\n", "--max-time", "3", "http://100.126.215.69:1235/health"], { timeout: 8000 }, (err, stdout) => {
      const m = stdout.trim().split("\n").pop();
      res(m === "200" ? "200" : "000");
    });
  });
}

const t0 = Date.now();
const iv = setInterval(async () => {
  const el = Math.round((Date.now() - t0) / 1000);
  let m = "";
  try { m = fs.readFileSync(LOG, "utf8").trim().split("\n").pop() || ""; } catch {}
  const h = await health();
  out(`[t+${el}s] health1235=${h} last=${m}`);
  if (h === "200" && el > 60) {
    out("[HEALTHY] waiting 20s for handler to finish, then exit");
    clearInterval(iv);
    setTimeout(() => {
      out("=== final markers ===");
      try { out(fs.readFileSync(LOG, "utf8")); } catch {}
      pi.kill();
      process.exit(0);
    }, 20000);
  }
}, 10000);

setTimeout(() => {
  out("[timeout 480s] final markers:");
  try { out(fs.readFileSync(LOG, "utf8")); } catch {}
  pi.kill();
  process.exit(1);
}, 480000);
