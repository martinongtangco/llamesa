import { createJiti } from "jiti";

const jiti = createJiti(import.meta.url, { interopDefault: true });

const commands = new Map();
const events = new Map();
const pi = {
  on: (name, handler) => events.set(name, handler),
  registerCommand: (name, opts) => commands.set(name, opts),
};

const mod = jiti(new URL("./index.ts", import.meta.url).href);
const factory = mod.default ?? mod;
factory(pi);

console.log("loaded OK");
console.log("commands:", [...commands.keys()].join(", "));
console.log("events:", [...events.keys()].join(", "));

const ctx = {
  mode: "tui",
  hasUI: true,
  ui: {
    notify: (msg, kind = "info") => console.log(`[notify:${kind}] ${msg}`),
    setStatus: (key, text) => console.log(`[status:${key}] ${text ?? "(cleared)"}`),
    select: async (title, options) => {
      console.log(`[select] ${title} -> (simulating pick of) ${options[0]}`);
      return options[0];
    },
    input: async (title, placeholder) => {
      console.log(`[input] ${title} (${placeholder}) -> (simulating blank)`);
      return undefined;
    },
    confirm: async (title, message) => {
      console.log(`[confirm] ${title}: ${message} -> (simulating NO/safe)`);
      return false;
    },
    custom: async (factoryFn, _opts) => {
      let closed = false;
      const done = (val) => { closed = true; return val; };
      const comp = factoryFn(
        {},
        { fg: (_c, s) => s, dim: (s) => s },
        { matches: (data, name) => name === "tui.select.cancel" && data === "\u001b" },
        done,
      );
      console.log("[modal render]");
      comp.render(100).forEach((l) => console.log("  " + l));
      comp.handleInput("\u001b");
      return closed ? "closed-ok" : "NOT-CLOSED";
    },
  },
};

const ss = events.get("session_start");
if (ss) await ss({}, ctx);

console.log("\n--- /llamesa (consolidated status + stat modal) ---");
await commands.get("llamesa").handler("", ctx);

console.log("\n--- /llamesa-stat: removed (consolidated into /llamesa) ---");
if (commands.has("llamesa-stat")) throw new Error("llamesa-stat should be unregistered");

console.log("\n--- autocomplete for /llamesa-start ---");
const comp = await commands.get("llamesa-start").getArgumentCompletions("");
console.log("suggestions:", comp ? comp.map((c) => c.value).join(", ") : "(none)");

console.log("\n--- /llamesa-stop: NOT executed in this harness ---");
console.log("(start/stop mutate the live server; verified separately when the box was idle)");
