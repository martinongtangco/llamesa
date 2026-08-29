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

## Max context: use `-big`

Weights plus compute buffers, then the cache on top. A 32GB R9700 gives you
~30.5 GiB to work with in practice; both cards under `-big` give ~61 GiB.

Full 262144 context:

| Quant | Weights + buffers | + f16 cache | + q8_0 cache | One card | `-big` |
|---|---|---|---|---|---|
| `Q6_K` | ~24.3 GiB | ~40.3 | ~32.3 | no | yes |
| `UD-Q6_K_XL` | ~26.5 GiB | ~42.5 | **~34.5** | no | **yes** |
| `Q8_0` | ~30.0 GiB | ~46.0 | ~38.0 | no | yes |
| `UD-Q8_K_XL` | ~32.3 GiB | ~48.3 | ~40.3 | no | yes |

Every quant fits the full window on `-big`, so the choice there is purely
speed — which is what makes `UD-Q6_K_XL` the pick. At ~34.5 GiB of ~61 you
have a lot of room left; f16 cache (~42.5 GiB) also fits if you'd rather not
quantise it at all.

Quantising the cache is worth it anyway at this context length, for a reason
beyond fitting: attention reads the *used* portion of the cache on every token.
A full f16 window means 16 GiB of cache traffic per token on top of 23.6 GiB of
weights. At q8_0 that's 8 GiB. It costs nothing while the conversation is
short and roughly halves the long-context penalty once it isn't.

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
existing config. `flash_attn` / `cache_type_k` / `cache_type_v` apply to
`start`, `-dual` and `-big` alike; put the same keys inside `vulkan_split` to
override them for `-big` only. `vulkan_split.default_context` overrides the
top-level `default_context` for `-big` only.

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
