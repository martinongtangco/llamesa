# Picking a model for coding on 2× R9700

Constraints this is solving for, in the order they were given: **coding is the
primary use**, **max context**, **use both cards**. They pull against each
other, and the pull is the whole point of this document.

## Why the 35B-A3B disappointed

Coding quality tracks **active** parameters, not total. `Qwen3.6-35B-A3B`
activates ~3B per token — that's the same reason it hits 99.9 tok/s on this
rig and the reason it's thin on multi-file work. It isn't a quantisation
problem or a config problem.

This is a documented pattern, not just a local impression: benchmark writeups
have `Qwen3.5-27B` (dense) beating `Qwen3.5-122B-A10B` (MoE, 10B active) on
coding specifically where complex multi-file reasoning needs full parameter
engagement, despite the MoE being 4.5× larger in total.

Two things follow. Ruling out *all* MoE would be the wrong lesson — the fix is
more active parameters, or a model actually trained on code, not necessarily
dense. But treating "total parameters" as a quality number is how you end up
disappointed again.

## The tension

| Goal | What it wants |
|---|---|
| Best coding | Dense 27B — ~26.6 GiB, leaves 34 GiB spare |
| Max context | The *smallest* model that's good enough — context is what you buy with the leftover VRAM |
| Fill both cards | A 45-57 GiB MoE — which leaves ~5-16 GiB for context |

**"Max context" and "fill the cards with a big model" are the same VRAM, spent
twice.** ~61 GiB is the budget; every GiB of weights is a GiB not available to
the KV cache. There's no configuration that maximises both — pick which one
the work actually needs.

## Candidates that fit ~61 GiB

| Model | Shape | Coding score | Size | Left for context |
|---|---|---|---|---|
| `Qwen3-Coder-Next` | 80B **A3B**, coding-trained | >70 SWE-bench Verified (SWE-Agent) | ~46 GB @ 4-bit | ~16 GiB |
| `Qwen3.5-122B-A10B` | 122B **A10B** | 72.4 SWE-bench Verified | 46.6 GB (IQ3_S) / 57 GB (Q3_K_XL) | ~15 GiB / ~5 GiB |
| `Qwen3.8-27B` | 27B dense, vision | 61.7 SWE-bench **Pro**, 73.0 Terminal-Bench 2.1, 90.3 LiveCodeBench v6 | 25.3 GB (UD-Q6_K_XL) | ~34 GiB |
| `Qwen3.6-27B` | 27B dense | 77.2 SWE-bench Verified | ~25 GB @ Q6 | ~34 GiB |
| `Qwen3.6-35B-A3B` | 35B A3B | — (tried, thin on code) | 40.8 GiB @ Q8 | ~20 GiB |

Scores are **not** all the same benchmark — SWE-bench Pro is materially harder
than Verified, so Qwen3.8-27B's 61.7 Pro is not a worse result than
Qwen3.6-27B's 77.2 Verified. Don't rank down that column.

## Recommendation

**Try `Qwen3-Coder-Next` first.** It's the one candidate that is
coding-specialised, fits at **Q4 rather than Q3** so quantisation isn't
quietly eating the gain, carries 262144 native context, and at ~3B active
should run several times faster than the dense 27B.

Yes, it's A3B — the shape that just disappointed. It's worth one test anyway,
because it differs on both axes that mattered: 80B total instead of 35B, and
trained for code rather than general-purpose. Unsloth's claim is that it
performs comparably to models with 10-20× more active parameters. Treat that
as a vendor claim and check it against your own repo, but it's a cheap test.

**If it disappoints the same way, go to `Qwen3.5-122B-A10B` at IQ3_S.** 10B
active is 3× the reasoning depth of A3B and the direct answer to the actual
complaint, with 72.4 SWE-bench Verified behind it. The cost is dropping to a
3-bit quant to leave room for context, which is a real quality risk on code —
prefer the I-quants (IQ3_S/IQ3_M) over Q3_K at this tier, they hold up better
per byte. `Q3_K_XL` (57 GB) scores better but leaves ~5 GiB, which is not
enough context to be worth it here.

**Keep `Qwen3.8-27B` as the reference.** When a task genuinely needs full
parameter engagement across many files, dense wins, and its ~34 GiB of spare
VRAM is also the only configuration that gives you a really large context. It
is the "max context" answer, not the "fill the cards" answer.

## The option that actually uses both cards

`-dual` runs a separate model per GPU, each with its own 32GB and no split
overhead — and on ROCm, which loads in ~6s rather than ~26s. That's a better
answer to "maximise my cards" than one large model spanning both:

- **Card A:** `Qwen3.8-27B` at Q6 — the deep-reasoning model for hard,
  multi-file work.
- **Card B:** a fast A3B coder for autocomplete, quick edits, and anything
  where latency beats depth.

Both resident, no reloading between them, each at full single-card speed.
Neither `-big`'s cross-GPU split nor its Vulkan requirement applies.

Note `Qwen3-Coder-Next` at ~46 GB does **not** fit a single card, so it's a
`-big` model. `Qwen3-Coder-30B-A3B` does — see
[below](#the-qwen3-coder-30b-a3b-you-already-have) for what it fits.

## The Qwen3-Coder-30B-A3B you already have

### The "1M" is a separate repo, not a quant

There are two repositories:

| Repo | Native max in GGUF metadata |
|---|---|
| `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF` | 262144 |
| `unsloth/Qwen3-Coder-30B-A3B-Instruct-1M-GGUF` | 1048576 |

Same weights, and every quant tier exists in both. The difference is that the
1M repo carries the YaRN rope config in its metadata, so llama.cpp reads a 1M
native maximum and you need no `rope_scaling` flags to use a window that large.
Check which one is on the box:

```bash
llamesa.sh model-context --path /var/mnt/games/models/<dir>/<file>.gguf
```

262144 means the standard repo, ~1048576 means the 1M one.

For any window **at or below 262144, prefer the standard repo.** The 1M repo's
scaling is baked in, which makes it static in the same way `rope_scaling` in
config is — it applies to short prompts too. Downloading the 1M repo to run a
128K window costs quality for nothing.

### Its context is more expensive than Qwen3.8-27B's

The counterintuitive part. Qwen3-Coder-30B-A3B has 48 layers, 32 query heads
and 4 KV heads, and **all 48 layers cache**, at head_dim 128:

`2 × 4 heads × 128 dim × 2 bytes × 48 layers = 98,304 bytes` — **96 KB per
token**, against Qwen3.8-27B's 64 KB. The smaller, faster model has the pricier
context, because Qwen3.8-27B's gated attention only caches 16 of its 64 layers.

| Context | f16 | q8_0 | q4_0 |
|---|---|---|---|
| 131072 | 12 GiB | 6 | 3 |
| 262144 | 24 GiB | 12 | 6 |
| 524288 | 48 GiB | 24 | 12 |
| 1048576 | **96 GiB** | 48 | 24 |

### What fits

Weights plus a ~2 GiB buffer allowance, against ~30.5 GiB on one card and ~61
GiB on `-big`. Totals use a **q8_0 cache**:

| Quant | Weights + buffers | 131072 | 262144 | 524288 | 1048576 |
|---|---|---|---|---|---|
| `UD-Q4_K_XL` (17.7 GB) | ~18 GiB | ~24 | ~30 | ~42 | ~66 ✗ |
| `Q6_K` (25.1 GB) | ~25 GiB | ~31 | ~37 | ~49 | ~73 ✗ |
| `Q8_0` (32.5 GB) | ~32 GiB | ~38 | ~44 | **~56** | ~80 ✗ |

**1048576 needs a q4_0 cache at any quant** (24 GiB, putting `Q8_0` at ~56 GiB
and `UD-Q4_K_XL` at ~42). That's the catch: a 4-bit KV cache is the wrong
economy for repo-scale code retrieval, which is the only reason to want 1M in
the first place. You'd be quantising away the recall you're paying for.

The good news is what this model *can* do, which the 27B can't: because the
weights are small, **`Q8_0` is affordable** — no quantisation compromise at all
— and still leaves room for a very large window.

- **`-big`, best overall:** `Q8_0` at **524288** with a q8_0 cache, ~56 GiB.
  Full-precision-grade weights and a half-megabyte window.
- **`-big`, no YaRN at all:** `Q8_0` at 262144 with an **f16** cache, ~56 GiB.
  Native window, lossless cache, no rope distortion on short prompts. This is
  the one to run if you want zero compromises.
- **One card (for `-dual`):** `UD-Q4_K_XL` at 262144, ~30 GiB. Tight but
  plausible, and it makes this the card-B model in the `-dual` pairing above.

Note 524288 still needs YaRN 2× on the standard repo — or the 1M repo, which
has it baked in. That's the one case where downloading the 1M repo earns its
keep.

## Constraints to carry over

- **MoE on `-big` must stay Vulkan.** The ROCm split-mode bug
  ([ggml-org/llama.cpp#21140](https://github.com/ggml-org/llama.cpp/issues/21140))
  hits MoE and hybrid-recurrent architectures under `-sm layer`/`-sm row`.
  Vulkan is already `-big`'s default; the "try ROCm for `-big`" note in
  [quantization.md](quantization.md#3-try-rocm-for-big) applies to dense models
  only and should be dropped the moment you switch to MoE. `-dual` is
  unaffected by construction (`-sm none`).
- **KV geometry is per-model.** The ~64 KB/token figure in
  [quantization.md](quantization.md#what-the-context-actually-costs) is
  Qwen3.8-27B's, derived from its 16-of-64 cached layers. Do not carry it to
  Coder-Next or the 122B — measure each with `llamesa.sh model-context` and
  `rocm-smi` before sizing a window.
- **MTP is Qwen3.8-specific.** `spec_type=draft-mtp` works because Qwen3.8's
  GGUFs carry `blk.*.nextn.*` tensors. Other models need their own MTP build or
  a separate draft model; the flag is inert without the tensors.

## Caveats

Benchmark figures here are from published writeups, not measured on this
hardware, and the columns mix benchmarks. The VRAM figures are file sizes plus
a rough buffer allowance. Everything in the "left for context" column assumes
~61 GiB usable across both cards. None of this substitutes for running two
candidates against your own repo — SWE-bench is not your codebase.
