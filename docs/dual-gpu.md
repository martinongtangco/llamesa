# Dual-GPU Guide: `-dual` and `-big`

This guide covers LLaMesa's two multi-GPU capabilities, added on top of the single-GPU
`start`/`stop`/`restart`/`status`/`logs` commands (and their `--gpu 0|1|all`-scoped
variants). Both are fully independent, additive command sets — neither touches how the
base commands work.

> **Read [Known Limitations](#known-limitations) before relying on either mode.** Both
> modes were verified against real hardware and both have open, partially-unresolved
> problems as of this writing: `-big` reliably offloads to GPU for models that fit on the
> R9700 alone, but its actual cross-GPU split (the point of `-big`) doesn't hold for larger
> models. `-dual`'s R9700 instance is confirmed working with real GPU offload; its RX 9060 XT
> instance is unverified pending a smaller test model. This doc describes the intended
> design; the limitations section describes what actually happens today.

| | `-dual` | `-big` |
|---|---|---|
| Backend | Vulkan (see note below) | Vulkan |
| Processes | Two independent `llama-server` processes | One process spanning both GPUs |
| VRAM | Each model limited to its own GPU's VRAM | Combined VRAM (~48GB on R9700 + RX 9060 XT) |
| Use when | Running two separate models at once (e.g. a chat model + a coder model) | One model too large for either GPU alone |
| Config block | `dual_gpu` | `vulkan_split` |

**Correction to the original design assumption:** this guide originally described `-dual`
as a ROCm/HIP path and `-big` as requiring a separate Vulkan build. Neither is true. The
`llama-server` binary on this box (`llama_binary` in both `gpus[]` and `dual_gpu` config
blocks) is actually a **Vulkan build with no ROCm/HIP support at all** — `--list-devices`
shows only `Vulkan0`/`Vulkan1`/`CPU`, never a ROCm device. This means:
- `-dual`'s `HIP_VISIBLE_DEVICES` / `HSA_OVERRIDE_GFX_VERSION` env vars (in the reference
  table below) do nothing — they're ROCm-only and this binary doesn't use ROCm. Per-GPU
  isolation for `-dual` is instead done via `-sm none -mg <index>` (an explicit
  `--device <name>` flag was tried first and never achieved real offload — see
  [Known Limitations](#known-limitations)), with the index dynamically resolved by
  matching VRAM size (mirrors `_resolve_drm_card`'s approach, since Vulkan device
  enumeration order is not stable across process launches on this hardware).
- `-big` needs **no separate Vulkan build** — the existing binary already supports
  `-sm`/`--tensor-split`/`--device`. There is no `build-vulkan` step to run.

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
| R9700 env | `RADV_DEBUG=nocompute`, `GPU_MAX_HW_QUEUES=1` |
| RX 9060 XT env | `HIP_VISIBLE_DEVICES=1`, `GGML_CUDA_NO_PEER_COPY=1`, `HSA_OVERRIDE_GFX_VERSION=12.0.1` (**non-functional** — ROCm-only vars, see correction above; kept here only because it's what the config actually contains) |
| Vulkan split env | `RADV_PERFTEST=nogttspill` |
| Vulkan tensor split ratio | `2,1` (approximates 32GB:16GB) — **applies to whichever device lands in position 0 vs 1**, and that order is not stable across process launches (observed flipping between runs). A ratio that's correct one launch can be backwards the next. |
| `--n-gpu-layers` | Must be `auto`, never a fixed number like the old `default_gpu_layers: 99` convention — see [Known Limitations](#known-limitations) |

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

Both verified against real hardware. Neither is fixable from `llamesa.sh` — both are
upstream llama.cpp / Vulkan driver issues.

### `-big`: cross-GPU split does not reliably hold

`-big` **does** achieve genuine GPU VRAM offload for models that fit on the R9700 alone —
confirmed with Qwen3.6-27B fully resident on GPU (17.8GB used, 0 system-RAM fallback,
stable indefinitely). That part works well.

For models that need *both* GPUs (Qwen3.6-35B-A3B at Q8, ~38.5GB), the split starts
correctly — early in loading, both GPUs show real VRAM usage proportional to
`tensor-split` (e.g. R9700 27.4GB / RX 9060 XT 12.1GB at 3 seconds in) — but the RX 9060 XT's
portion silently evicts to system RAM by the time loading finishes, every time, with no
error or warning anywhere in the log. Tested both with `-fit` on (default) and explicitly
`--fit off` with a manually-forced `--tensor-split 2,1 --n-gpu-layers 999` — identical
result either way, which rules out `-fit`'s heuristics as the sole cause and points at a
deeper bug in llama.cpp's Vulkan backend for genuine multi-device tensor-split allocation.

No confirmed matching upstream issue — don't take the absence of a citation here as "this
is novel and unreported," just that a search didn't turn up an exact match. A similarly-named
report, [ggml-org/llama.cpp#15974 "Tensor split on vulkan broken"](https://github.com/ggml-org/llama.cpp/issues/15974),
turned out **not** to be it: that issue is closed (fixed by PR #16039) and described a
different scenario entirely (an iGPU + an NVIDIA eGPU over Thunderbolt), not two discrete
same-vendor GPUs on one machine. Worth re-searching GitHub issues before assuming this is
still-open behavior, in case it's been reported and fixed since this was written — check
whether a newer llama.cpp build resolves it before spending time on further workarounds
here. `-fit`'s own immaturity ([#22592](https://github.com/ggml-org/llama.cpp/issues/22592),
[#21801](https://github.com/ggml-org/llama.cpp/issues/21801)) is real but was ruled out as
the sole cause here, since disabling `-fit` didn't change the outcome.

**Bottom line:** `-big` is reliable for models ≤ the R9700's 32GB. For models genuinely
needing combined VRAM, expect the overflow to land in system RAM rather than the RX 9060 XT
— check `free -h` / `status-big`'s per-device `devices[]` array before assuming a large
model is actually using both cards.

### `-dual`: R9700 confirmed fixed; RX 9060 XT still unverified

Earlier in testing, every `-dual` load attempt fell back to CPU/system RAM for both
instances, regardless of fix attempted:
- Original (`HIP_VISIBLE_DEVICES` env-based isolation): fails, since the binary is Vulkan
  not ROCm — those env vars are inert.
- `--device Vulkan0`/`Vulkan1` pinning + hardcoded `--n-gpu-layers 99`: `rx9060xt` hits an
  explicit `-fit` abort ("n_gpu_layers already set by user to 99, abort"); both instances
  end up on CPU.
- `--device` pinning + `--n-gpu-layers auto`: no abort warning, but both instances *still*
  show near-zero VRAM (~57-67MiB) and full system-RAM fallback.

This was confirmed to be a **v1-wide issue, not `-dual`-specific** at the time: v1's plain
single-GPU `start` command, with no `-dual` code involved at all, showed the identical
failure mode.

**Fix found and applied:** `--device <single-name>` (restricting Vulkan device visibility
to exactly one device) never achieved real offload in any test. Replacing it with
`-sm none -mg <index>` — leaving *both* devices visible and explicitly selecting one via
`--main-gpu` for compute, the same approach that partially worked for `-big`'s
`-sm layer --tensor-split` — fixed it for the R9700: confirmed via both a standalone manual
test and the real `start-dual` command, real VRAM offload (~26.7GB), stable, reproducible,
system RAM staying low (~4-5GB, no fallback). `_resolve_vulkan_device_index` in
`server/llamesa.sh` resolves the correct numeric index by matching `--list-devices`
output against target VRAM size (mirroring `_resolve_drm_card`'s approach, since Vulkan
device index/enumeration order isn't stable across launches).

**RX 9060 XT is still unresolved, but for a different, more mundane reason:** every model
available for testing (Qwen3.6-27B, Qwen3-Coder-30B) is ~16GB — exactly the RX 9060 XT's
total VRAM, leaving zero headroom for KV cache/context. With `-sm none -mg 1` pinning to
it specifically, only ~1.4GB landed on GPU and the rest fell back to system RAM. This
*might* be the same underlying bug still present for that specific card, or it might be
completely legitimate "doesn't fit" behavior now that real GPU placement is actually being
attempted (unlike before, where neither card ever got real placement to compare against).
**Needs a smaller model (safely under ~12GB) to get a clean read** — nothing currently
downloaded fits that criteria.

**Bottom line:** trust `status-dual`'s `vram_used_bytes` for the R9700 instance now — it's
verified. For the RX 9060 XT instance, keep checking `free -h` for elevated RAM before
assuming it's using the GPU, until this gets a clean test with a smaller model.

### Related safety measure

Because both limitations above manifest as *silent* CPU/RAM fallback rather than an error,
a large model (or several stacked at once) can quietly consume all system RAM and trigger
a kernel OOM event — this happened once during testing and required a hard reboot. `-big`,
`-dual`, and v1's `start` all now refuse to launch a model whose file size doesn't leave
enough available system RAM headroom (`check_ram_safety` in `server/llamesa.sh`), as a
backstop against repeating that — but this guard doesn't fix the underlying fallback, it
only prevents it from crashing the machine.

---

## Troubleshooting

**"no dual_gpu config found" / "no vulkan_split config found"** — the corresponding
config block isn't in `~/.llamesa/config.json` yet. Add it by hand (see above); LLaMesa
will not create it for you.

**`-big` never responds within a few minutes** — check `llamesa.sh logs-big` (or
`~/.llamesa/big.log` directly). First-time Vulkan shader compilation on newer GPU
architectures can be slow; if the log shows no progress at all, confirm the binary path
in `vulkan_split.llama_binary` actually exists and `--list-devices` still shows both GPUs.

**`start-dual` only shows one GPU active** — check `llamesa.sh logs-dual --gpu <id>` for
that instance specifically. Each instance is a fully separate process/log/PID file
(`~/.llamesa/dual-r9700.*` and `~/.llamesa/dual-rx9060xt.*`), so a failure on one never
affects the other. The R9700 instance's VRAM usage is confirmed reliable (see
[Known Limitations](#known-limitations)); the RX 9060 XT instance is still unverified —
"shows inactive" there may mean the model silently fell back to CPU rather than a process
failure, especially for models near its 16GB capacity.

**A model appears loaded/responsive but VRAM looks empty** — for `-big`, expected for
models over ~32GB (see [Known Limitations](#known-limitations)). For `-dual`, expected
only for the RX 9060 XT instance with tight-fitting models — the R9700 instance is
confirmed reliable. Check `free -h` for elevated RAM usage as confirmation either way.

**Do not attempt ROCm split-mode flags on this hardware.** `gfx1201` (RDNA4) has a
confirmed illegal-memory-access/segfault bug with ROCm tensor/layer split. `-dual` exists
specifically to avoid this by using two independent processes instead — this still
matters even with the R9700 fix in place, since the fix (`-sm none -mg <index>`) is a
Vulkan flag combo, not a ROCm one; don't substitute ROCm split-mode flags when working on
the still-open RX 9060 XT question above.
