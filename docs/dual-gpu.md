# Dual-GPU Guide: `-dual` and `-big`

This guide covers LLaMesa's two multi-GPU capabilities, added on top of the single-GPU
`start`/`stop`/`restart`/`status`/`logs` commands (and their `--gpu 0|1|all`-scoped
variants). Both are fully independent, additive command sets — neither touches how the
base commands work.

> **Read [Known Limitations](#known-limitations) before relying on either mode.**
> `-dual` is confirmed fully working on both GPUs, now that it runs on a dedicated ROCm
> build (see [Two backends](#two-backends-why-dual-is-rocm-and-big-is-vulkan) below).
> `-big` is confirmed working for genuine cross-GPU splits too, **as long as it's started
> from a clean VRAM state on both cards** — see [Known Limitations](#known-limitations) for
> what "clean" means and why this caveat exists. This doc describes what's confirmed to
> work today, not an aspirational design.

| | `-dual` | `-big` |
|---|---|---|
| Backend | **ROCm/HIP** (dedicated build, see below) | Vulkan |
| Processes | Two independent `llama-server` processes | One process spanning both GPUs |
| VRAM | Each model limited to its own GPU's VRAM | Combined VRAM (~48GB on R9700 + RX 9060 XT) |
| Use when | Running two separate models at once (e.g. a chat model + a coder model) | One model too large for either GPU alone |
| Config block | `dual_gpu` | `vulkan_split` |
| Status | **Confirmed working**, both GPUs | **Confirmed working**, genuine cross-GPU splits up to ~48GB combined, *from a clean VRAM starting state* |

---

## Two backends: why `-dual` is ROCm and `-big` is Vulkan

Earlier iterations of this guide assumed the single `llama_binary` shared by v1's
`start`/`stop`/`restart` and (originally) by `-dual`/`-big` was a ROCm build, based on the
distrobox container being named `rocm-r9700`. That was never true — the container name is
just a label. `CMakeCache.txt` for that binary shows `GGML_HIP:BOOL=OFF` /
`GGML_VULKAN:BOOL=ON`, and the binary's timestamp predates the entire dual-GPU git history.
**It has always been a Vulkan build.** `vulkan_split.llama_binary` (used by `-big`) and the
top-level `llama_binary` / `gpus[].llama_binary` (used by v1's `start`) are deliberately
left pointing at this original Vulkan binary — no reason to touch what already works.

`-dual`, however, now uses a **separate, purpose-built ROCm/HIP binary**, built specifically
because ROCm eliminates a whole class of Vulkan behavior that made `-dual` unreliable to
reason about (silent CPU/RAM fallback with no error — see
[Known Limitations](#known-limitations)). With `-dual`'s process-per-GPU design
(`-sm none -mg <index>`, each instance only ever sees one GPU), ROCm's stricter behavior
(hard fail instead of silent fallback — see below) is a feature, not a risk, because you
find out immediately if a model doesn't fit rather than discovering it later via `free -h`.

`-big` stays on Vulkan because Vulkan's graceful spill-to-RAM (slow, but not a crash) is
actually useful for the tensor-split path, and because `-big`'s open cross-GPU bug (see
[Known Limitations](#known-limitations)) is not a backend-availability problem — moving it
to ROCm would not fix it and would trade a slow-but-alive failure mode for an outright OOM.

### Building the ROCm binary

Built as a fresh, independent clone — the original Vulkan build is never touched:

```bash
# Inside the rocm-r9700 distrobox container (Ubuntu 22.04)
sudo apt-get install -y hipblas-dev   # pulls in hipblas-common-dev, hipblaslt-dev,
                                        # rocblas-dev, rocsolver-dev, rocsparse(-dev)
                                        # ROCm 7.2.4 itself must already be installed

git clone https://github.com/ggml-org/llama.cpp ~/llama.cpp-rocm
cd ~/llama.cpp-rocm
mkdir build-rocm && cd build-rocm

CC=/opt/rocm/lib/llvm/bin/clang CXX=/opt/rocm/lib/llvm/bin/clang++ \
  cmake .. -DGGML_HIP=ON -DAMDGPU_TARGETS="gfx1200;gfx1201" \
           -DCMAKE_BUILD_TYPE=Release -DLLAMA_SERVER_LOGFILE=ON

make -j12   # ~1 hour: most of the time is spent compiling fattn/mmq GPU kernel
            # template instances; it speeds up a lot once past those into plain C++
```

Resulting binary: `~/llama.cpp-rocm/build-rocm/bin/llama-server`. Confirm both GPUs are
visible before pointing config at it:

```bash
~/llama.cpp-rocm/build-rocm/bin/llama-server --list-devices
# ROCm0 = RX 9060 XT (16GB), ROCm1 = R9700 (32GB)
```

**That index mapping (`ROCm0`/`ROCm1`) is not guaranteed stable across launches** — same
caveat as the Vulkan binary's `Vulkan0`/`Vulkan1`. This is why `_resolve_device_index` in
`server/llamesa.sh` re-resolves the correct index from `--list-devices` output on every
launch (matching by VRAM size) rather than hardcoding it. The function is backend-agnostic:
its regex matches `[A-Za-z]+([0-9]+):`, so the same code path handles `Vulkan0`/`Vulkan1`
or `ROCm0`/`ROCm1` depending on which binary a given `dual_gpu.<gpu>.llama_binary` points
at.

---

## Config setup

Both `dual_gpu` and `vulkan_split` are **optional, top-level** keys in
`~/.llamesa/config.json`, additive to everything already there. LLaMesa never writes
these automatically — you add them by hand. If either block is missing, the
corresponding commands fail fast with a clear error rather than silently falling back to
defaults.

See [config/server.example.json](../config/server.example.json) for the exact JSON
shape (nested under an inert `_dual_gpu_example` wrapper key so the example file stays
valid JSON — copy `dual_gpu` and `vulkan_split` out to the top level of your real config).

Reference values for this hardware:

| Setting | Value |
|---|---|
| R9700 port | `1234` |
| RX 9060 XT port | `1235` |
| Vulkan split (`-big`) port | `1236` |
| `dual_gpu.r9700.llama_binary` / `dual_gpu.rx9060xt.llama_binary` | ROCm build, e.g. `~/llama.cpp-rocm/build-rocm/bin/llama-server` |
| `dual_gpu.r9700.env` / `dual_gpu.rx9060xt.env` | `{}` — no env vars needed. In particular, do **not** set `HIP_VISIBLE_DEVICES`: it restricts the device list `_resolve_device_index` reads from `--list-devices`, which conflicts with `-sm none -mg <index>` needing to see and select from *both* devices. |
| `vulkan_split.llama_binary` (`-big`) | Original Vulkan build, unchanged |
| Vulkan tensor split ratio | `2,1` (approximates 32GB:16GB) — **applies to whichever device lands in position 0 vs 1**, and that order is not stable across process launches (observed flipping between runs). A ratio that's correct one launch can be backwards the next. |
| `--n-gpu-layers` | Must be `auto`, never a fixed number like the old `default_gpu_layers: 99` convention — a hardcoded value makes `-fit` abort ("n_gpu_layers already set by user... abort") instead of picking the right split |

Back up your config before editing:

```bash
cp ~/.llamesa/config.json ~/.llamesa/config.json.bak
```

---

## Command reference

### `-dual`

```bash
llamesa.sh start-dual --model-r9700 "<model>" --model-rx9060xt "<model>" [--thinking true] [--ctx 131072]
llamesa.sh stop-dual [--gpu r9700|rx9060xt]        # omit --gpu to stop both
llamesa.sh restart-dual [--gpu r9700|rx9060xt]     # remembers each instance's last model
llamesa.sh status-dual [--gpu r9700|rx9060xt]      # omit --gpu for a JSON array of both
llamesa.sh logs-dual --gpu r9700|rx9060xt          # --gpu is required, no combined tail
```

Stopping or restarting one GPU leaves the other instance running untouched.

### `-big`

```bash
llamesa.sh start-big --model "<model>" [--thinking true] [--ctx 131072]
llamesa.sh stop-big
llamesa.sh restart-big --model "<model>" [--thinking true] [--ctx 131072]   # model is required — not remembered
llamesa.sh status-big
llamesa.sh logs-big
```

### Windows client (`llamesa.ps1`)

The menu's **MULTI-GPU** section adds `/start-big`, `/stop-big`, `/restart-big`,
`/start-dual`, `/stop-dual`, `/restart-dual`. The header switches to a per-mode layout
automatically once one of these is started:

- **`-big` header**: single stats row with side-by-side per-device VRAM/GPU% mini-bars.
- **`-dual` header**: two full stats rows, one per GPU, each with its own model/ctx/thinking line.

`/chat` prompts you to pick which GPU's endpoint to talk to when a `-dual` session with
both instances running is active; otherwise it behaves exactly as it does for a single
server or a `-big` session.

---

## Known Limitations

### `-dual`: confirmed working on both GPUs (ROCm) — but no VRAM-overflow safety net

End-to-end tested on ROCm: Qwen3.6-27B on R9700 (27.3GB VRAM, stable) + Qwen3-8B-Q8_0 on
RX 9060 XT (10.9GB VRAM, 100% GPU busy, actually computing — 31.6 tok/s) simultaneously,
ctx=8192 each. System RAM stayed at 6.1GB with 0 swap — zero CPU fallback on either GPU.
No `Vulkan`/`RADV` anywhere in the logs, genuinely running on ROCm.

This works because of `-dual`'s process-per-GPU design: `-sm none -mg <index>`, each
instance only ever sees and computes on one GPU, resolved dynamically via
`_resolve_device_index` (see [Building the ROCm binary](#building-the-rocm-binary) above).
`--device <name>` pinning was tried first and never achieved real GPU offload on either
backend (always silently fell back to system RAM); `-sm none -mg <index>` — leaving both
devices visible to the process but explicitly selecting one via `--main-gpu` — is what
actually works.

**Important trade-off: ROCm has no graceful VRAM-overflow fallback, by design.** Per a
direct llama.cpp maintainer response
([ggml-org/llama.cpp#21376](https://github.com/ggml-org/llama.cpp/issues/21376)):
> "Rocm doesn't spill to system vram by design unless hipManaged Memory is used, this is
> not a bug."

Unlike the Vulkan binary (which silently spills overflow to system RAM — slow, but the
server stays alive), the ROCm binary used by `-dual` will **crash/OOM outright** if a model
plus its KV cache doesn't fit in the target GPU's VRAM. This is permanent upstream
behavior, not a bug waiting on a fix. `check_ram_safety()` (see
[Related safety measure](#related-safety-measure) below) guards against *system RAM*
exhaustion, but it cannot protect against this — a ROCm VRAM overflow is a GPU-memory
problem, not a system-RAM problem, and check_ram_safety has no visibility into it. **Always
size `-dual` models conservatively, leaving real headroom for KV cache**, since there is no
fallback to catch a too-large request.

There was a real, narrow ROCm split-mode bug on this exact hardware
([ggml-org/llama.cpp#21140](https://github.com/ggml-org/llama.cpp/issues/21140), confirmed
on 2x R9700 gfx1201; fix submitted as
[PR #21170](https://github.com/ggml-org/llama.cpp/pull/21170), confirmed working by the
reporter on the same hardware, but still open/unmerged as of this writing) — but it only
affects hybrid recurrent/Mamba-SSM architectures (Qwen3.5/3.6-A3B-style models) during
prompt-cache restore in multi-turn conversations, and only under `-sm layer`/`-sm row`
split modes that spread a *single* model's weights across multiple GPUs. `-dual`'s design
(`-sm none`, each instance only ever sees one GPU) never triggers this by construction,
regardless of whether the fix is merged — it's not a concern for `-dual`, only relevant if
someone experiments with ROCm split-mode flags directly (see
[Troubleshooting](#troubleshooting)).

### `-big`: cross-GPU split works reliably from a clean VRAM state

Earlier testing concluded `-big`'s cross-GPU split was fundamentally broken: for models
needing both GPUs, the split would start correctly (both GPUs briefly showing real,
proportional VRAM usage) but the RX 9060 XT's portion would silently evict to system RAM
by the time loading finished, every time, with no error in the log. That was documented
here as an open, unresolved upstream mystery — ruled out `-fit` heuristics, ruled out
MoE-specific CPU-preference behavior, found no matching upstream issue after a deep
research pass.

**Re-tested from a clean VRAM state, and it now holds reliably.** Four separate models,
each started only after confirming both GPUs showed near-zero VRAM used (`free -h` flat,
no stray `llama-server` processes, sysfs VRAM readings low on both cards):

| Model | Architecture | Combined VRAM | R9700 | RX 9060 XT | Ctx | Speed |
|---|---|---|---|---|---|---|
| Qwen3.6-27B | dense, 27B | 35.2GiB | 23.7GiB | 11.5GiB | 131072 | ~26-27 tok/s |
| Qwen3.6-35B-A3B Q8 | MoE, 35B (~3B active) | 40.8GiB | 28.1GiB | 12.7GiB | 131072 | 99.9 tok/s |
| Meta-Llama-3.1-70B-Instruct Q3_K_L | dense, 70B | 47.4GiB | 31.7GiB | 15.7GiB | 50176 | ~7.8 tok/s |
| Qwen2.5-72B-Instruct Q3_K_S | dense, 72B | 47.5GiB | 31.7GiB | 15.8GiB | 32768 | ~7.9 tok/s |

All four are genuine cross-GPU splits (none fit on the R9700's 32GB alone), all held a
real, stable 2:1-ish proportional split matching `tensor-split`, all showed 0 system-RAM
fallback (`free -h` stayed flat, no swap growth), and all ran real generations
successfully. The last two are extremely tight (under 1GiB combined headroom out of
~47.8GiB total) but still didn't evict — this is right at the edge of what the hardware
can hold, not a lot of safety margin, but it's real GPU memory doing real work, not a
silent RAM fallback.

**Revised theory:** the original failures were very likely caused by leftover/orphaned
VRAM occupying the RX 9060 XT at test time — the same class of leak documented in this
session's investigation (a killed `-dual`/`-big` process can leave VRAM allocated on the
driver side without a live process to account for it; see the operational lesson at the
bottom of this section). A dirty starting state on the RX 9060 XT would have silently
shrunk its real free VRAM, causing the split to appear to "evict" when it was actually
just running out of genuinely free room — indistinguishable from a driver bug unless you
check GPU VRAM state independently of `llamesa.sh`'s own tracking before each test, which
the original testing didn't consistently do. **This is inferred from a change in testing
discipline, not from any code fix** — no llama.cpp/Vulkan-side change was made. Confidence
is reasonably high (4/4 clean passes across both a MoE and dense architecture, including
the two exact models that failed before) but not certain; if a future test evicts again,
check VRAM state on both cards *before* concluding the old bug is back.

**Bottom line:** before starting `-big` for a model that needs both GPUs, verify both
cards are actually near-empty first — `free -h` alone isn't enough, since a VRAM leak
doesn't show up in system RAM. Check `status-big`'s `devices[]` array or GPU VRAM sysfs
directly. If either card already has significant VRAM in use with no corresponding running
process, clean that up (see [Related safety measure](#related-safety-measure)) before
trusting a `-big` test result either way.

### Related safety measure

If a model genuinely doesn't fit even after a clean-VRAM `-big` start (or if multiple test
processes stack up without full cleanup, regardless of backend), it can still fall back to
system RAM the old way and quietly consume all of it, triggering a kernel OOM event. This
happened once during testing and
required a hard reboot. `-big`, `-dual`, and v1's `start` all refuse to launch a model
whose file size doesn't leave enough available system RAM headroom (`check_ram_safety` in
`server/llamesa.sh`), as a backstop against repeating that. **This guard only protects
system RAM** — it does not, and cannot, protect against `-dual`'s ROCm binary OOMing on
*VRAM* (see above); that risk has to be managed by sizing models conservatively up front.

---

## Troubleshooting

**"no dual_gpu config found" / "no vulkan_split config found"** — the corresponding
config block isn't in `~/.llamesa/config.json` yet. Add it by hand (see above); LLaMesa
will not create it for you.

**`-big` never responds within a few minutes** — check `llamesa.sh logs-big` (or
`~/.llamesa/big.log` directly). First-time Vulkan shader compilation on newer GPU
architectures can be slow; if the log shows no progress at all, confirm the binary path
in `vulkan_split.llama_binary` actually exists and `--list-devices` still shows both GPUs.

**`start-dual` crashes / process dies instead of starting** — this is almost always the
ROCm "no VRAM overflow fallback" behavior (see [Known Limitations](#known-limitations)):
the requested model + context doesn't fit in that GPU's VRAM, and ROCm fails hard rather
than spilling to RAM like Vulkan would. Check `llamesa.sh logs-dual --gpu <id>` for an
OOM/allocation-failure message, and retry with a smaller model or lower `--ctx`.

**`start-dual` only shows one GPU active** — check `llamesa.sh logs-dual --gpu <id>` for
that instance specifically. Each instance is a fully separate process/log/PID file
(`~/.llamesa/dual-r9700.*` and `~/.llamesa/dual-rx9060xt.*`), so a failure on one never
affects the other.

**A model appears loaded/responsive but VRAM looks empty on `-big`** — no longer expected
behavior for models that need both GPUs (see [Known Limitations](#known-limitations); this
was the old documented failure mode, now believed fixed by starting from a clean VRAM
state). Check `free -h` for elevated RAM as confirmation of a real fallback, and check
both GPUs' VRAM sysfs to rule out one of them already being dirty from a leftover process
before assuming the split itself is broken again. For `-dual` on the ROCm binary this should not happen — if
placement failed, the process should have crashed rather than silently falling back (that's
the whole point of using ROCm here). If you see this on `-dual`, something is
misconfigured — double check `dual_gpu.<gpu>.llama_binary` actually points at the ROCm
binary and not the original Vulkan one.

**Do not experiment with ROCm split-mode flags (`-sm layer`/`-sm row` spreading one model
across both GPUs) on this hardware.** `gfx1201` (RDNA4) hit a confirmed bug in that path
([#21140](https://github.com/ggml-org/llama.cpp/issues/21140), fix in unmerged
[PR #21170](https://github.com/ggml-org/llama.cpp/pull/21170)) affecting hybrid
recurrent/Mamba-SSM models during prompt-cache restore. `-dual` avoids this entirely by
design — `-sm none`, one GPU per process — so this only matters if you're manually testing
the ROCm binary outside of `llamesa.sh`.

**Before/after every `-dual` or `-big` test**: check `ps aux | grep llama-server` and
`free -h` to confirm full cleanup from the previous run before starting the next —
stacking multiple test processes without confirming cleanup is what caused the kernel
OOM/hard-reboot mentioned above. For `-big` specifically, also check each GPU's VRAM sysfs
directly (`/sys/class/drm/card<N>/device/mem_info_vram_used`) — `free -h` only shows
system RAM and won't reveal a GPU with leftover VRAM from a killed process, which is
believed to have caused the original (now-resolved) cross-GPU split failures. If a
background `stop-dual`/`stop-big` SSH command appears to hang, the remote command has
sometimes still completed fine — verify via a fresh SSH connection checking
`ps aux`/`free -h` rather than assuming failure or retrying blindly.
