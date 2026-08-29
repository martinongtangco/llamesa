# Picking a quant: Qwen3.8-27B on a 32GB R9700

Notes from moving this rig's daily driver off Q8. The short version: on a
single 32GB R9700, **any Q8 of a 27B forces a cross-GPU `-big` split, and a Q6
doesn't** — and the Q6 also reads ~20-25% fewer bytes per token, which is what
generation speed on a dense model is actually bound by.

Recommended file: **`Qwen3.8-27B-UD-Q6_K_XL.gguf`** (25.3 GB) from
[unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF).

## The ladder

| File | Size | Fits one R9700 (32GB)? | Notes |
|---|---|---|---|
| `Qwen3.8-27B-Q6_K.gguf` | 22.9 GB | Yes, with room to spare | Most headroom; take this if you want 131072 ctx at f16 KV |
| `Qwen3.8-27B-UD-Q6_K_XL.gguf` | **25.3 GB** | **Yes** | **Recommended.** Unsloth Dynamic v3.0; best quality per byte at a size that still fits one card |
| `Qwen3.8-27B-UD-Q8_K_L.gguf` | 28.0 GB | No (weights alone leave no KV room) | `-big` only |
| `Qwen3.8-27B-Q8_0.gguf` | 29.0 GB | No | `-big` only |
| `Qwen3.8-27B-UD-Q8_K_XL.gguf` | 31.5 GB | No | `-big` only |

Vision is a separate file — add `mmproj-F16.gguf` (0.93 GB) to the same
directory if you want it. `llamesa` auto-detects `mmproj-*.gguf` and passes
`--mmproj` for you, on all three start paths.

Two things worth knowing about the Unsloth files specifically: the Qwen3.8-27B
GGUFs were re-cut on 2026-08-19 to Unsloth Dynamic v3.0, so a copy pulled
before that date is the older cut at the same size — re-download rather than
assume. And the `UD-*_XL` files are not just "bigger Q6"; they spend the extra
bytes on the layers that are most sensitive to quantisation, which is why
`UD-Q6_K_XL` is the pick over plain `Q6_K` unless you specifically need the
2.4GB back for context.

## Why Q8 was the slow choice here

Generation on a dense 27B is memory-bandwidth bound: every token reads the
whole weight set. Bytes per token scale directly with the quant size, so
dropping from `UD-Q8_K_XL` (31.5 GB) to `UD-Q6_K_XL` (25.3 GB) is ~25% fewer
bytes to move, and from `Q8_0` (29.0 GB) it's ~15%. That is roughly the tok/s
you get back, before anything else.

Splitting across both R9700s doesn't buy speed back. Under `-sm layer` the
GPUs run their layers in sequence, not in parallel — each card reads only its
own half, so two identical cards land at about single-card speed plus the
handoff, not double. That matches what's already in
[docs/dual-gpu.md](dual-gpu.md): dense Qwen3.6-27B at `UD-Q6_K_XL` measured
20.05 tok/s on Vulkan `-big` and 21.08 tok/s on ROCm. Combined VRAM is what
`-big` is for; throughput isn't.

So the win from fitting on one card is not raw bandwidth — it's that you stop
paying the split's overhead, you get the ROCm path (~6s model load vs ~26s on
the Vulkan `-big` binary, same doc), and you leave the second R9700 free for a
`-dual` model alongside it.

## Making it fit: quantise the KV cache

The weights are the fixed cost; the KV cache is the part that grows with
context. Extrapolating from this rig's own measured Qwen3.6-27B numbers
(27.3 GiB at ctx 8192, 35.2 GiB at ctx 131072, both `UD-Q6_K_XL`), an f16
cache costs roughly **64 MiB per 1K tokens** on a 27B. At `q8_0` that's about
half.

Estimated total VRAM for `UD-Q6_K_XL` (~26.8 GiB of weights and compute
buffers, plus cache):

| Context | f16 KV | q8_0 KV |
|---|---|---|
| 32768 | ~28.8 GiB — fits | ~27.8 GiB — fits |
| 65536 | ~30.9 GiB — very tight | ~28.8 GiB — fits |
| 131072 | ~35.2 GiB — needs `-big` | ~30.9 GiB — very tight |

These are estimates carried over from Qwen3.6-27B, not measurements of
Qwen3.8-27B. Treat the "very tight" rows as things to verify against
`rocm-smi` before relying on them, and remember that ROCm does not spill to
system RAM — it OOMs outright (see
[dual-gpu.md, Known Limitations](dual-gpu.md#known-limitations)). Start at
65536 with a `q8_0` cache and work up.

## Configuring it

Download on the Bazzite box:

```bash
llamesa.sh download --repo unsloth/Qwen3.8-27B-GGUF --file "*UD-Q6_K_XL*"

# vision projector, optional — same directory, picked up automatically
llamesa.sh download --repo unsloth/Qwen3.8-27B-GGUF --file "mmproj-F16.gguf"
```

Then turn on the quantised KV cache in `~/.llamesa/config.json`:

```bash
jq '.flash_attn = "on" | .cache_type_k = "q8_0" | .cache_type_v = "q8_0"' \
  ~/.llamesa/config.json > /tmp/llamesa-config.json \
  && mv /tmp/llamesa-config.json ~/.llamesa/config.json
```

All three keys are optional. Omit them and the command line is byte-for-byte
what it was before they existed, so this is safe to add to an existing config.
They apply to `start`, `-dual` and `-big` alike; put the same keys inside the
`vulkan_split` block to override them for `-big` only.

`flash_attn` takes either a string (emitted as `--flash-attn <value>`, for
builds that expect `on|off|auto`) or `true` (emitted as a bare `--flash-attn`,
for older builds that take no argument). If the server fails to start with an
argument-parsing error on `--flash-attn`, switch to `true`. Flash attention is
required for a quantised V cache, so setting `cache_type_v` without
`flash_attn` implies `"on"`.

That lands in `<models_dir>/Qwen3.8-27B-GGUF/`, which is the name `/start`
and `list-models` will show it under. Then start it on one GPU and pick 65536
when asked for context:

```
/start → Qwen3.8-27B-GGUF → single GPU
```

Sampling settings Qwen recommends for 3.8: `temperature=0.7`, `top_p=0.8`,
`top_k=20`, `repetition_penalty=1.05`. Native context is 256K, so the client
will offer far more than fits — the ceiling here is VRAM, not the model.
