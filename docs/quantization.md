# Picking a quant: Qwen3.8-27B on a dual-R9700 rig

Notes from moving this rig's daily driver off Q8. Two separate questions get
tangled together here, so take them in order:

1. **Which quant?** `Qwen3.8-27B-UD-Q6_K_XL.gguf` (25.3 GB) from
   [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF).
   Q8 moves ~20-25% more bytes per token for no quality you'll notice.
2. **Which mode?** If you want the full 262144-token window, `-big`. No quant
   of a 27B reaches 256K on a single 32GB card without gutting the KV cache.

## The ladder

| File | Size | Notes |
|---|---|---|
| `Qwen3.8-27B-Q6_K.gguf` | 22.9 GB | Most headroom; the pick if you want max context on *one* card |
| `Qwen3.8-27B-UD-Q6_K_XL.gguf` | **25.3 GB** | **Recommended.** Unsloth Dynamic v3.0; best quality per byte |
| `Qwen3.8-27B-UD-Q8_K_L.gguf` | 28.0 GB | |
| `Qwen3.8-27B-Q8_0.gguf` | 29.0 GB | |
| `Qwen3.8-27B-UD-Q8_K_XL.gguf` | 31.5 GB | |

Vision is a separate file — add `mmproj-F16.gguf` (0.93 GB) to the same
directory if you want it. `llamesa` auto-detects `mmproj-*.gguf` and passes
`--mmproj` for you, on all three start paths.

Two things worth knowing about the Unsloth files specifically: the Qwen3.8-27B
GGUFs were re-cut on 2026-08-19 to Unsloth Dynamic v3.0, so a copy pulled
before that date is the older cut at the same size — re-download rather than
assume. And the `UD-*_XL` files are not just "bigger Q6"; they spend the extra
bytes on the layers most sensitive to quantisation, which is why `UD-Q6_K_XL`
beats plain `Q6_K` unless you specifically need the 2.4GB back for context.

## Why Q8 was the slow choice

Generation on a dense 27B is memory-bandwidth bound: every token reads the
whole weight set, so bytes per token scale directly with quant size. Dropping
from `UD-Q8_K_XL` (31.5 GB) to `UD-Q6_K_XL` (25.3 GB) is ~25% fewer bytes to
move; from `Q8_0` (29.0 GB) it's ~15%. That's roughly the tok/s you get back.

That gap is at its widest on short turns, though. Once a very large window is
actually full the cache read dominates and the quants converge — see
[the tok/s table](#what-it-costs-in-toks) before assuming Q8 is always the
wrong call.

Splitting across both R9700s doesn't buy the speed back. Under `-sm layer` the
cards run their layers in sequence, not in parallel — each reads only its own
half, so two identical cards land at about single-card speed plus the handoff,
not double. That matches [docs/dual-gpu.md](dual-gpu.md): dense Qwen3.6-27B at
`UD-Q6_K_XL` measured 20.05 tok/s on Vulkan `-big`, 21.08 on ROCm. Combined
VRAM is what `-big` buys; throughput isn't.

## What the context actually costs

Qwen3.8-27B is cheaper per token than its size suggests. It has 64 layers but
only **16 of them keep a KV cache** (gated attention, GQA 24 query heads / 4 KV
heads at head_dim 256). That works out to
`2 × 4 heads × 256 dim × 2 bytes = 4 KB` per cached layer per token, so:

**~64 KB per token at f16 — about 64 MiB per 1K tokens.**

Community measurements line up: ~0.5 GB at 8K, ~2.0 GB at 32K, ~16.4 GB at the
full 262144 window. So for the whole native context:

| Cache type | KV at 262144 |
|---|---|
| f16 | ~16.0 GiB |
| q8_0 | ~8.0 GiB |
| q4_0 | ~4.0 GiB |

Native context is 262144 with no YaRN or rope scaling needed to reach it —
that's the real ceiling, not a stretched one. Check yours directly:

```bash
llamesa.sh model-context --path /var/mnt/games/models/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q6_K_XL.gguf
```

## The whole matrix

Weights plus compute buffers, then the cache on top. A 32GB R9700 gives you
~30.5 GiB in practice; both cards under `-big` give ~61 GiB. Totals below
assume a **q8_0 cache** (32 MiB per 1K tokens); double the cache portion for
f16.

| Quant | Weights + buffers | 131072 | 262144 | 524288 | 1048576 |
|---|---|---|---|---|---|
| `Q6_K` | ~24.3 GiB | ~28.3 | ~32.3 | ~40.3 | ~56.3 |
| `UD-Q6_K_XL` | ~26.6 GiB | ~30.6 | ~34.6 | ~42.6 | ~58.6 |
| `UD-Q8_K_L` | ~29.1 GiB | ~33.1 | ~37.1 | ~45.1 | ~61.1 |
| `Q8_0` | ~30.0 GiB | ~34.0 | ~38.0 | ~46.0 | ~62.0 |
| `UD-Q8_K_XL` | ~32.3 GiB | ~36.3 | ~40.3 | ~48.3 | ~64.3 |

Read it against two lines: **~30.5 GiB** fits one card, **~61 GiB** fits
`-big`. Only the 131072 column has anything that fits a single GPU. Everything
through 524288 fits `-big` with room; at 1048576 only the two Q6 rows clear it.

Anything past 262144 needs YaRN — see [below](#what-about-yarn).

### What it costs in tok/s

Generation is bandwidth-bound, so tok/s tracks bytes read per token: the
weights every time, plus the *used* portion of the cache. Calibrating against
this rig's measured 20.05 tok/s (`UD-Q6_K_XL` on `-big`, Vulkan) gives ~480
GiB/s effective, which puts the rest at:

| Quant | Short context | Full 524288 (q8_0 cache) |
|---|---|---|
| `Q6_K` | ~22.5 tok/s | ~12.9 |
| `UD-Q6_K_XL` | ~20.4 tok/s | ~12.1 |
| `UD-Q8_K_L` | ~18.4 tok/s | ~11.4 |
| `Q8_0` | ~17.8 tok/s | ~11.2 |
| `UD-Q8_K_XL` | ~16.4 tok/s | ~10.6 |

Two things fall out of that. First, the quant gap is widest when the cache is
empty — `Q8_0` is ~15% behind `UD-Q6_K_XL` on a short turn, but only ~9%
behind once a 524288 window is actually full, because by then the cache is the
larger read. **If you genuinely work at enormous context most of the time, the
quant matters less.** If your turns are mostly short, which is typical, you pay
the full gap constantly.

Second, everything converges to 11-13 tok/s at a full 524288 window regardless
of quant. Context length dominates quant choice for speed, so pick the window
you'll actually use rather than the largest one that fits.

### Why quantise the cache

Beyond fitting: attention reads the used cache on every token. A full 262144
window is 16 GiB of cache traffic per token at f16 and 8 GiB at q8_0. It costs
nothing while the conversation is short, and roughly halves the long-context
penalty once it isn't.

### If you'd rather stay on one GPU

Single-card ceilings with a q8_0 cache, which is what the top-level
`default_context` in [config/server.example.json](../config/server.example.json)
is set for:

| Quant | Max context on one 32GB R9700 |
|---|---|
| `UD-Q6_K_XL` | ~131072 |
| `Q6_K` | ~196608 |

`Q6_K` with a **q4_0** cache does technically reach 262144 (~28.3 GiB), but a
4-bit V cache degrades exactly the long-range recall you wanted the big window
for. Don't. If you need 256K, use `-big`.

You don't have to pick once, either — `default_context` is only a default, and
`/start` still lets you choose per session. Running single-GPU at 131072 for
day-to-day speed and switching to `-big` when you actually need the full window
is a reasonable way to live.

## What about YaRN

Anything past 262144 needs it, so both 524288 and 1048576 land here. The two
are very different propositions.

### 524288 (2×) — comfortable, and Q8 survives it

Every quant fits, with 12-20 GiB to spare on `-big`:

| Quant | + q8_0 cache @ 524288 (16 GiB) | Spare of ~61 GiB |
|---|---|---|
| `Q6_K` | ~40.3 GiB | ~20.7 |
| `UD-Q6_K_XL` | ~42.6 GiB | ~18.4 |
| `UD-Q8_K_L` | ~45.1 GiB | ~15.9 |
| `Q8_0` | ~46.0 GiB | ~15.0 |
| `UD-Q8_K_XL` | ~48.3 GiB | ~12.7 |

So keeping a Q8 *and* doubling the window is a real option — this is the one
place the Q8-vs-Q6 argument softens. At a full 524288 window `Q8_0` is only
~9% behind `UD-Q6_K_XL` rather than ~15%, because the 16 GiB cache read
dominates the weight difference (see [the tok/s table](#what-it-costs-in-toks)).
An f16 cache does not fit at this window for any Q8 — `Q8_0` + f16 is ~62 GiB,
just over — so q8_0 cache is mandatory here.

The catch is that the ~15% gap is still there on every *short* turn, which is
most turns, and you're paying the static-YaRN short-prompt tax on top. Q8 at
524288 makes sense if you genuinely live at long context; if your turns are
mixed, Q6 at 524288 gives you the same window and is faster at both ends.

### 1048576 (4×) — fits, barely, and costs a lot

A 1048576-token window costs `1048576 × 64 KB` of cache: **64 GiB at f16, 32
GiB at q8_0, 16 GiB at q4_0**. Against `-big`'s ~61 GiB:

| Quant | Weights + buffers | + q8_0 cache @ 1M | Verdict |
|---|---|---|---|
| `Q6_K` | ~24.3 GiB | ~56.3 | fits, ~4.7 GiB spare |
| `UD-Q6_K_XL` | ~26.5 GiB | ~58.5 | ~2.5 GiB spare — too thin to trust |
| either | | + f16 cache: ~88-90 | no |

So the only version of this with real margin is **`Q6_K` with a q8_0 cache** —
the plain Q6, not the `UD` one. Note that's a straight reversal of the
recommendation above: at 1M you no longer have the VRAM to spend on quantisation
quality, so you spend it on cache instead.

Four things to weigh before you do:

**Generation gets ~3× slower at full context.** Attention reads the used cache
on every token. At 1M filled that's 32 GiB of cache traffic on top of 21.3 GiB
of weights — ~53 GiB per token, against ~21 GiB at short context. Against
measured ~20-21 tok/s on `-big` today, expect roughly 7-11 tok/s with the
window full. This started as a tok/s exercise; 1M is the most expensive thing
you can do to tok/s.

**The VRAM is spent whether you use it or not.** llama.cpp allocates the whole
KV cache at load, so `-c 1048576` means 32 GiB gone at startup even for a
two-line prompt.

**Prefill is measured in tens of minutes.** Ingesting an actual 1M-token prompt
is a long wait before the first token, and you pay it again on any cache miss.

**Static YaRN degrades short prompts too.** llama.cpp applies the rope scale to
every request, not just long ones — it has no idea how long your prompt is
going to be. A 4× scale to reach 1M is in force on a "hey, fix this function"
turn as well.

That last one is fixable, and it's why the config keys are scoped: put the rope
keys **inside `vulkan_split`**, not at the top level, and only `-big` sessions
pay for them while `start` and `-dual` stay on the native window.

```bash
jq '.vulkan_split.default_context = 1048576
    | .vulkan_split.rope_scaling = "yarn"
    | .vulkan_split.rope_scale = 4
    | .vulkan_split.yarn_orig_ctx = 262144' \
  ~/.llamesa/config.json > /tmp/llamesa-config.json \
  && mv /tmp/llamesa-config.json ~/.llamesa/config.json
```

For 2× to 524288, the same block with `rope_scale` at 2:

```bash
jq '.vulkan_split.default_context = 524288
    | .vulkan_split.rope_scaling = "yarn"
    | .vulkan_split.rope_scale = 2
    | .vulkan_split.yarn_orig_ctx = 262144' \
  ~/.llamesa/config.json > /tmp/llamesa-config.json \
  && mv /tmp/llamesa-config.json ~/.llamesa/config.json
```

`llamesa` warns on stderr whenever `rope_scaling` is active, so a session that's
running scaled is never running scaled silently.

One more thing worth knowing: Qwen ships 1M for Qwen3.8-27B only on the
**hosted** version. The open weights are 262144 native, and pushing 4× past
that with YaRN is unvalidated territory — expect recall at 1M to be a lot worse
than the number suggests. Models generally degrade well before their nominal
window, and stacking a 4× extension on a quantised cache compounds it.

### Picking between them

| | 262144 | 524288 | 1048576 |
|---|---|---|---|
| YaRN | none | 2× | 4× |
| q8_0 cache | 8 GiB | 16 GiB | 32 GiB |
| Quants that fit `-big` | all | all | Q6 only |
| f16 cache an option? | yes, all quants | Q6 only | no |
| tok/s, window full | ~14-15 | ~11-13 | ~7-9 |
| Short-prompt quality | untouched | 2× rope tax | 4× rope tax |

**262144 is the default worth keeping.** It's native, needs no YaRN, costs no
short-prompt quality, leaves f16 cache on the table, and is already a very
large window. Take **524288** if you actually hit that wall — it's the one
extension that stays comfortable, and it's where a Q8 remains defensible.
Treat **1048576** as an experiment rather than a daily driver.

## Configuring it

Download on the Bazzite box:

```bash
llamesa.sh download --repo unsloth/Qwen3.8-27B-GGUF --file "*UD-Q6_K_XL*"

# vision projector, optional — same directory, picked up automatically
llamesa.sh download --repo unsloth/Qwen3.8-27B-GGUF --file "mmproj-F16.gguf"
```

That lands in `<models_dir>/Qwen3.8-27B-GGUF/`, which is the name `/start` and
`list-models` will show it under.

Then, in `~/.llamesa/config.json` — quantised cache everywhere, and the full
window as `-big`'s default:

```bash
jq '.flash_attn = "on"
    | .cache_type_k = "q8_0"
    | .cache_type_v = "q8_0"
    | .default_context = 131072
    | .vulkan_split.default_context = 262144' \
  ~/.llamesa/config.json > /tmp/llamesa-config.json \
  && mv /tmp/llamesa-config.json ~/.llamesa/config.json
```

All of these keys are optional. Omit them and the command line is
byte-for-byte what it was before they existed, so this is safe to add to an
existing config. `flash_attn`, `cache_type_k`, `cache_type_v`, `rope_scaling`,
`rope_scale` and `yarn_orig_ctx` apply to `start`, `-dual` and `-big` alike;
put any of them inside `vulkan_split` to override for `-big` only, which is
how you confine YaRN to the sessions that need it.
`vulkan_split.default_context` overrides the top-level `default_context` the
same way.

`flash_attn` takes either a string (emitted as `--flash-attn <value>`, for
builds expecting `on|off|auto`) or `true` (a bare `--flash-attn`, for older
builds that take no argument). If the server fails to start with an
argument-parsing error on `--flash-attn`, switch to `true`. Flash attention is
required for a quantised V cache, so setting `cache_type_v` without
`flash_attn` implies `"on"`.

Then:

```
/start-big → Qwen3.8-27B-GGUF → 262144
```

Start `-big` from a clean VRAM state on both cards — see
[dual-gpu.md, Known Limitations](dual-gpu.md#-big-cross-gpu-split-works-reliably-from-a-clean-vram-state)
for why that caveat exists and how to confirm it.

Sampling settings Qwen recommends for 3.8: `temperature=0.7`, `top_p=0.8`,
`top_k=20`, `repetition_penalty=1.05`.

## Caveats

- The weights-plus-buffers column is the file size plus a ~3 GiB allowance for
  compute buffers, derived from this rig's own measured Qwen3.6-27B figures
  (27.3 GiB at ctx 8192, 35.2 GiB at 131072). The cache column rests on
  Qwen3.8-27B's documented attention geometry, not on extrapolation. Neither
  is a measurement of Qwen3.8-27B on this hardware — check `rocm-smi` before
  trusting anything in the last GiB.
- ROCm does not spill to system RAM; it OOMs outright. The Vulkan binary
  `-big` uses does spill, silently and slowly. Both failure modes are covered
  in [dual-gpu.md](dual-gpu.md#known-limitations).
- `-big`'s cross-GPU split reliability was last measured on the old asymmetric
  R9700 + RX 9060 XT pair. It has not been re-validated on the current
  symmetric pair.
