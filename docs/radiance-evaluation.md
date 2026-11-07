# Radiance evaluation for dual R9700 (draft, 2026-11-07)

Status: research, baseline and a single-GPU Radiance trial are done (2026-11-07). Nothing existing on the host was changed and nothing was deployed. Section (c) has the measurements; (d) is the recommendation: run alongside, do not switch yet.

How the web facts were gathered: pages were fetched through a fetch tool that sometimes summarises long pages. Where a number comes from a summarised part of a page, it is marked [summary] and should be checked against the page before you quote it. Several docs (Radiance `docs/GUIDE.md`, the vllm-radiance GitLab docs, Hugging Face model cards) could not be read. The Puget Systems article could not be found, so no independent Puget numbers are included.

## (a) Claims, verified vs unverified

Nothing below was reproduced by me. "Independent" means someone other than the engine author or the thread starter ran it.

| # | Claim | Model / quant | TP | Concurrency | Context | Engine version | Hardware | Source | Status |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 124 to 130 tok/s single-stream, 586 to 596 aggregate at c8 | Qwen3.8-27B and Swift1.5 FP8 dense | 2 | 1 and 8 | not stated (Breakout test used a 6,567-token prompt) | not stated ("latest") | 2x R9700, Ryzen 9950X3D | [L1T thread, post 1](https://forum.level1techs.com/t/258397) | Self-reported. Not reproduced. Speculative decoding on/off is not stated. |
| 2 | 678 aggregate at c8 | Qwen3.8-27B MXFP4 | 2 | 8 | not stated | not stated | 2x R9700 | same | Self-reported |
| 3 | 137 single, 1,103 peak aggregate at c16 | Flash-Next MoE (about 6B active) | 2 | 1 and 16 | not stated | not stated | 2x R9700 | same | Self-reported. A commenter says he sees higher. |
| 4 | 179 single, 324 aggregate c8 | Swift1.5 FP8 dense | 4 | 1 and 8 | not stated | not stated | 4x R9600D, EPYC 9575F | same | Self-reported. Different GPU, not R9700. |
| 5 | Non-spec 53.3 / 101.8 / 181.4 / 304.1 aggregate at c1/c2/c4/c8 | Qwen3.8-27B native FP8, FP8 KV | 2 | 1 to 8 | 8K | vLLM 0.30.0 plus libr4d 0.5.0, dated 2026-09-22 | 2x R9700 | [vllm-radiance README](https://github.com/magiccodingman/vllm-radiance) [summary] | Self-reported by the fork owner. Not reproduced. |
| 6 | Same stack with DFlash2 K5/K7: c1 154.2 / 173.5, c8 610.4 / 510.2 | same plus drafter | 2 | 1 to 8 | 8K | same | 2x R9700 | same [summary] | Self-reported. README itself labels it experimental. |
| 7 | MTP K4: c1 128.7, c8 463.9 | same | 2 | 1 to 8 | 8K | same | 2x R9700 | same [summary] | README says the tool-call gate FAILED (29/30). |
| 8 | 128K context at c4 with no OOM, 576,001 KV tokens | Quark MXFP4 (18.44 GiB weights) | 2 | 4 | 128K | same | 2x R9700 | same [summary] | Self-reported capacity test |
| 9 | Single-GPU INT4: 23 to 24 tok/s single, 74 at c4, 97 at c8 | RedHatAI Qwen3.8-27B-INT4 | 1 | 1, 4, 8 | 131,072 | Radiance-patched vLLM 0.28.0 | 1x R9700 | [Radiance-vLLM-AMD-R9700](https://github.com/christopherpaquin/Radiance-vLLM-AMD-R9700) | Self-reported, single maintainer. Page says this profile is outside the primary qualification. |
| 10 | Gemma 4 31B w4a8: 103 prose / 141 code tok/s | Gemma 4 31B | not stated | not stated | not stated | no version | 2x R9700 | [Radiance README](https://codeberg.org/StillDeadcode/radiance) | Self-reported, no commit |
| 11 | GLM-5.3-Flash: 166 single, 426 over 8 | MXFP4 | 8 | 1, 8 | not stated | no version | 8x R9700 | same | Self-reported |

Who reproduced what in the [thread](https://forum.level1techs.com/t/258397) (7 posts):

- wendell (thread starter, Level1Techs admin): wrote the numbers. In post 5 he says some figures might be R9600 numbers mixed in, that the post was "a bit pre-publish", and that Radiance had been updated since. Not resolved in the thread.
- digitalscream (post 4 and 6): has two R9700 on a Threadripper 3960X, but says he has not run any tests. He reports "agentic lowest 149 tok/s, average north of 190" for Flash-Next and says dense FP8 is closer to 130 to 140 tok/s, which contradicts the OP's ordering. Informal, not a reproduction. He also asked whether the 9950X3D rig ran its cards at x8/x8 or x16/x4; nobody answered.
- Mora and TheoneandonlymrK: only reproduced "the model wrote a working Breakout game". Mora gave no hardware or numbers. TheoneandonlymrK used a single 7900 AI PRO with other apps and gave no tok/s.
- Nobody independent reproduced a tok/s figure. The thread has no crash reports, which also means nobody stress-tested it there.

Internal inconsistencies in the OP that matter when quoting it: the title says 180B but no 180B model appears in the tables; the text says "five of six" games worked but the table says six Yes; one reasoning-loop run is 255,555 tokens in the text and 921,676 in the table; the headline "147 to 242 tok/s single-stream" matches the Breakout column, not the single-stream column.

Issues in the Radiance tracker that bear on claims (titles only, bodies not read): [#382](https://codeberg.org/StillDeadcode/radiance/issues) says release 1.16.0 changed Flash-Next outputs and dropped parallel tool calls with thinking off from about 80% to about 20%; #328 says 1.13.0 lowered Qwen3.8-27B MXFP4 GSM8K by 5.7 points. Two quality regressions in a month of releases means any number needs a pinned version.

## (b) Compatibility and risk summary

### What I checked on the host (read-only, over SSH)

| Item | Finding |
|---|---|
| OS and kernel | Bazzite 44, kernel 7.2.4-ogc3.1.fc44 |
| Container runtime | podman 5.8.7 and distrobox. No docker. Radiance documents Docker only; it ran fine under rootless podman with `--device /dev/kfd --device /dev/dri --security-opt seccomp=unconfined --security-opt label=disable --group-add keep-groups`. |
| Distrobox `rocm-r9700` | Up, ROCm 7.2.4 userspace. Radiance's image says it needs only a host amdgpu driver, not host ROCm. |
| Devices | `/dev/kfd`, `/dev/dri/card1`, `card2`, `renderD128`, `renderD129` |
| GPUs | Two Radeon AI PRO R9700 (Navi 48, 1002:7551), 34.2 GB VRAM each, resizable BAR active (32 GB BAR0 on both) |
| RAM | 62 GiB total, 55 GiB available |
| Disk | `/var/mnt/games` 287 GB free |
| Running inference at first check | None found (`llama-server`, radiance, vllm) |
| Local models | Qwen3.6-27B-GGUF, Qwen3.8-27B-GGUF, Qwen3.6-35B-A3B (HF and GGUF), Qwen3-Coder-30B |
| llama.cpp builds | Port 1236 (`vulkan_split`) uses `~/.local/share/distrobox/rocm-r9700/llama.cpp-vulkan-mtp/build/bin/llama-server`, build 10680, commit d7bd3bfca (2026-08-28). `~/llama.cpp` is at 9dbc6621a and `~/llama.cpp-rocm` at 64c8b7db7; `~/llama.cpp-vulkan-latest` from my notes no longer exists. |

### PCIe layout and P2P

Both cards report PCIe 5.0 x16 at the card, but that is the link inside the card's own switch. The upstream links differ:

- Card at 06:00.0 sits behind the X570S chipset. Its upstream bridge 04:00.0 runs at 16 GT/s x4, so this card effectively has PCIe 4.0 x4 to the CPU.
- Card at 0f:00.0 hangs off a CPU root port (03.1) with an x16 PCIe 4.0 link.

So peer traffic between the cards crosses the chipset uplink (about 8 GB/s each way, shared with NVMe, SATA and USB). This matches the thread warning from digitalscream about chipset-connected slots (unverified for Radiance, and his 40% figure came from llama.cpp dispatch latency). I cannot say whether P2P works on this board without running a test. Radiance runs a startup P2P and peer-copy bandwidth sweep, and its examples for larger rigs use `--p2p off`.

I could not map `card1`/`card2` to the two PCI addresses with certainty. The baseline step should do that.

### Radiance support vs what you use today

| You rely on | Radiance status |
|---|---|
| Qwen3.6-27B Q4_K_XL GGUF | Not supported. GGUF is not an input format. Qwen3.6-27B is not in the model list; only Qwen3.6-35B-A3B FP8 is. The closest dense model is Qwen3.8-27B (FP8 29 GiB, MXFP4 19 GiB, bf16 50 GiB). That is a different model, so output quality and agent behaviour must be re-judged. |
| Vision via mmproj | Qwen3.8 is listed as vision capable. No documented vision test, and nothing about Qwen3.6-27B vision. |
| 131,072 context | Serve flags in the README use `--max-model-len 200000` for Qwen3.8-27B; the fork qualifies 128K at c4 on two cards. Plausible, not tested here. |
| OpenAI-compatible API, tool calls | README lists OpenAI chat, Responses and Anthropic Messages endpoints, tool calls returned as `tool_calls`, `reasoning_content`, and `chat_template_kwargs.enable_thinking`. Issue #382 (parallel tool calls with thinking off) targets your exact workload. |
| Several agents at once | Up to 32 sequences per step, but hybrid Qwen3.8-27B is documented at 8. Fine for your 2 to 4. |
| llama.cpp Vulkan with nocompute workarounds | Not applicable. Radiance uses its own HIP kernels. Whether the gfx1201 ROCm crash you hit in llama.cpp applies is unknown and must be tested. |
| Windows client | Unaffected. It talks to the server over SSH and HTTP. |

### Risks

1. TP2 hangs. Open issues #415 (exact all-reduce hangs both GPUs, process never exits, resetting the display card can freeze the machine), #409, and #356 (both cards wedge in an all-reduce kernel, peer to peer). These are the exact mode a two-card TP2 run would use. Your cards are not symmetrically connected, which makes this riskier than the rigs in the thread.
2. Release churn: 17 releases from 2026-10-19 to 2026-11-04 (10 of 38 tags read), two reported quality regressions.
3. Speculative decoding gives most of the headline numbers. The fork's own README says spec decoding is not qualified (matched 1 of 8 fixed outputs) and the MTP lane failed a tool-call gate. Non-spec TP2 FP8 at c1 is 53 tok/s [summary].
4. Podman and SELinux on Bazzite: worked in the single-GPU trial with the flags in the table above.
5. Model switch: you would lose your current Qwen3.6-27B setup and re-download about 19 to 29 GB of safetensors.

Rollback for any trial: `podman rm -f` the trial container, delete the trial model directory and the trial config entry. Nothing in the existing install is edited.

## (c) Baseline vs Radiance benchmark table

All numbers were measured on this machine on 2026-11-07 (host clock), one run per cell unless a range is shown. Raw logs are in `~/radiance-eval/out` on the host.

Setups:

- llama.cpp: Vulkan build 10680 (commit d7bd3bfca, the `llama.cpp-vulkan-mtp` binary your port 1236 uses), Qwen3.8-27B Q8_0 (27.0 GiB), `-sm layer -ts 1,1` across both GPUs, flash attention, q8_0 KV, 131072 context, 4 slots (1 slot for the 100k and single-stream MTP tests). Measured plain and with MTP speculation (`--spec-type draft-mtp --spec-draft-n-max 3`).
- Radiance 1.17.0 (image digest 6fb0e99bfb86 per Docker Hub), podman, one GPU (TP1), `qwen3.8-27b-mxfp4.rad` (18.05 GiB, MXFP4 with a merged DFlash2 drafter), fp8 KV, 131072 max length, 8 sequences. "No spec" is `--num-speculative-tokens 0`. "Spec" is the default.
- Model note: the models differ. Your Qwen3.6-27B Q4_K_XL file is not on the host. Qwen3.8-27B Q8_0 was the only 27B GGUF there, and it is also what `big_session.json` shows as the last `-big` model. Radiance's precision (4-bit) is lower than Q8_0, and no quality gap was measured beyond the small checks below.
- Thinking was off in every request.

### llama-bench (llama.cpp only, 3 repetitions, tok/s)

| | pp512 | pp4096 | pp16384 | tg128 |
|---|---|---|---|---|
| GPU 0 alone | 523.6 | 502.0 | 449.5 | 19.9 |
| GPU 1 alone | 532.1 | 511.2 | 454.5 | 20.7 |
| Both, layer split | 437.1 | 734.8 | 663.1 | 19.1 |

### Agent-style prompt (3,848 tokens in, short tool-call reply out), 3 rounds

llama.cpp was measured twice: as first run (no speculation) and with its MTP head enabled (`--spec-type draft-mtp --spec-draft-n-max 3`, the head ships inside the Qwen3.8 GGUF; I only noticed after the first round, so it was rerun). The MTP rows are the fair comparison for Radiance's speculation rows.

| Concurrency | Metric | llama.cpp | llama.cpp + MTP | Radiance no spec | Radiance spec |
|---|---|---|---|---|---|
| c1 | decode per stream, tok/s | 20.8 to 21.2 | 60.8 to 62.2 | 38.8 to 44.0 | 170 to 205 |
| c1 | time to first token | 8.3 s | 10.7 s | 1.0 to 1.5 s | 0.8 to 1.3 s |
| c2 | decode per stream | 19.2 to 19.3 | 32.2 to 34.5 | 38.2 to 42.8 | 161 to 209 |
| c2 | time to first token | 14.6 to 15.2 s | 20.8 to 22.0 s | 1.6 to 1.7 s | 1.5 to 1.6 s |
| c4 | decode per stream | 16.4 to 16.8 | 4.8 to 20.0 (one stream stalls at 5 to 6) | 36.8 to 40.9 | 144 to 185 |
| c4 | time to first token | 35 to 39 s | 35 to 46 s | 3.0 to 4.2 s | 2.8 to 3.1 s |

The replies are only about 50 tokens, so decode figures here are noisy, and tool-call JSON is easy to predict. Treat both speculation columns as upper bounds.

### Longer outputs and long contexts, 1 round each

| Test | Metric | llama.cpp | llama.cpp + MTP | Radiance no spec | Radiance spec |
|---|---|---|---|---|---|
| 1,024-token code reply, c1 | decode tok/s | 18.9 | 48.2 | 27.3 | 145.2 |
| 1,024-token code reply, c4 | decode per stream | 14.9 | 12.8 to 13.0 | 30.7 to 30.8 | 73.0 to 76.8 |
| 1,024-token code reply, c4 | total tok/s (4 streams) | about 60 | about 52 | about 123 | about 300 |
| 30k prompt, c1 | time to first token | 41.9 s | 86.3 s | 10.1 s | 10.3 s |
| 30k prompt, c1 | decode after prefill | 18.3 | 27.4 | 35.5 | 71.2 |
| 100k prompt, c1 | time to first token | 199.4 s | 408.6 s | 54.0 s | 53.2 s |
| 100k prompt, c1 | decode after prefill | 15.6 | 25.5 | 31.6 | 70.6 |

Reading it fairly:

- Prefill: Radiance is about 4 times faster than plain llama.cpp at 30k and 100k, and about 6 times faster at 4k. MTP makes llama.cpp's prefill about twice as slow (the draft head is also filled), so against llama.cpp + MTP the prefill gap is 8 times at 30k and 7.5 times at 100k.
- Decode, single stream: llama.cpp + MTP closes much of the gap on short tool calls (61 vs 40 tok/s for Radiance without speculation) but Radiance with speculation is still about 3 times faster on code (145 vs 48).
- Decode under load: llama.cpp + MTP does not help at 4 slots (13 tok/s per stream, below plain llama.cpp's 14.9), while Radiance keeps 31 tok/s per stream without speculation and about 75 with it. For several agents at once this is the largest practical difference.
- Radiance's speculation figures depend on speculation acceptance, which was not measured separately.

### Maximum context on one card (Radiance, `--max-model-len 262144`, started with `start-rad --ctx 262144`)

| Test | Result |
|---|---|
| KV cache at startup | 391,200 tokens (14.44 GiB), 1.5 full-length sessions. At 131072 the pool was 484,928 tokens; the larger setting reserves more per-sequence state for 8 sequences. |
| 249,895-token prompt, code at 15% | found (`7311-QX`), 223.6 s to first token, 21.0 tok/s |
| 249,895-token prompt, code at 85% | found, 214.1 s to first token, 21.0 tok/s |
| Two 110k prompts at once | both found their code, about 118 s to first token for each |
| Errors, preemption, OOM, GPU reset | none in the container log or kernel log. One startup warning: the card settled with 187.6 MiB free against 208.3 MiB wanted, leaving about 75 MiB for a kernel's first launch, so the card is tight at this setting. |

A single card therefore holds the model's full 262144 context, so a TP2 split is not needed for context length. This is one retrieval question per prompt, not a quality evaluation. Using fewer sequences (`--parallel`) would leave more room for KV.

### Beyond the native context on one card (YaRN x2, `--max-model-len 409600 --rope-scaling yarn:2 --max-num-seqs 1`)

The model's trained context is 262144. Radiance's `docs/YARN.md` documents `--rope-scaling yarn:FACTOR` (static YaRN, applied to every request) and says retrieval was checked at about 500K tokens, with the caveat that accuracy "must be measured on the model and workload". This was run by hand with a separate container, not through `start-rad` (the deployed script has no rope flag; `radiance.extra_args` in the config would carry it).

| Test | Result |
|---|---|
| Startup | ready, KV cache 12.83 GiB = exactly one 409,600-token session; the card had 1.74 GiB left unclaimed, so a somewhat longer window might fit on one card (not tested) |
| 395,117-token prompt, code at 5% / 50% / 90% | found at all three (`7311-QX`) |
| Time to first token | 398.5 s / 397.6 s / 329.2 s |
| Decode after prefill | 17.5 / 17.1 / 17.2 tok/s |
| Short-prompt tool-call test with YaRN on | 35/40, same as without; vision answer unchanged |
| Errors, wedges, GPU resets | none in the container log or kernel log |

Limits: the same code string was hidden in every prompt (positions and filler text differed), the question was one retrieval per prompt, and I did not measure any quality loss on ordinary prompts beyond the 40 tool-call prompts. Static YaRN applies to all requests, so the llama.cpp notes about short-prompt quality loss apply in principle. It handles one sequence at a time, so it suits a single long-context agent, not several.

### Two instances, one per GPU (same model on each, 200000 context, speculation on)

Started with the new `start-rad` (both GPUs by default), ports 1237 and 1238, served names `qwen3.8-27b-a` and `qwen3.8-27b-b`. Measured with a throwaway config and container names, then confirmed again through the deployed client.

| Test | Result |
|---|---|
| Start, both instances together | ready in 20 s (24 s through the client); each card about 31 GiB used; about 28 GB of system RAM in use with both (about 11 GB of pinned memory per instance) |
| Names and context | `/v1/models` shows each instance's own name and `max_model_len` 200000 |
| Does the server enforce the model name? | No. A request to port 1237 naming `qwen3.8-27b-b`, and one naming a model that does not exist, were both answered. The name is a label, not a routing key. |
| Tool-call test on both at once | 35/40 on each instance (same as a single instance) |
| Vision | "Red" on both |
| Code reply (1,024 tokens), one agent per GPU at the same time | 108.3 and 154.0 tok/s |
| Code reply, two agents on ONE instance | 158.6 and 156.1 tok/s |
| Short agent prompt, one agent per GPU at the same time | 172 to 190 and 177 to 224 tok/s, first token 1.2 to 1.4 s |
| 100k prompt on both GPUs at the same time | first token 59.3 s and 45.6 s (one alone: 53 s), so the cards do not slow each other down |
| Earlier, two 110k prompts at once on one instance | about 118 s each, because the prefills ran one after the other |
| Scoped commands | `stop-rad --gpu r9700b` stopped only B; `restart-rad --gpu r9700b` brought it back with its remembered context and thinking setting; `logs-rad` without `--gpu` refused with a clear message; `stop-rad` left no container or listener |

What this means:

- A single instance already serves two agents' decode at full speed (about 157 tok/s each). The 108 tok/s result is probably speculation variance from different generated text, not a hardware gap; I did not repeat it enough to say.
- The second instance pays off for prompt processing: two long prompts prefill in parallel on two GPUs (about a minute for 100k each) instead of one after the other (about two minutes), and each agent gets its own cache of finished conversations.
- Each instance can hold a 200000-token window; with 8 sequences per instance the KV cache is shared among that instance's agents.
- Not measured: sustained load for hours, per-instance speed with both cards decoding long outputs for many minutes, and prefix-cache hit rates across a real agent session.

#### Both instances at the model's full 262144 context (the deployed default)

`radiance.default_context: 262144` is the context `start-rad` uses when `--ctx` is not given, and the client suggests it. Checked on the host with `start-rad` and no `--ctx`:

| Test | Result |
|---|---|
| Start, both instances | ready in 20 s; each reports `max_model_len` 262144 and about 31 GiB VRAM |
| KV cache per card | 14.40 GiB (390,048 tokens) on GPU A and 14.85 GiB (404,704 tokens) on GPU B, about 1.5 full-length sessions each; 2.32 GiB of that is per-sequence state for 8 sequences |
| Headroom at start | 88 MiB free on GPU A for a kernel's first launch (a warning in the log), 220 MiB on GPU B |
| 249,895-token prompt on both GPUs at the same time, code at 50% | found on both; first token 193.1 s and 180.3 s; decode 21.0 and 21.7 tok/s |
| Errors, wedges, GPU resets | none in the container logs or the kernel log |

So each GPU holds one full 262144-token session plus about half of another. Memory is tight at this setting (the small headroom is the log's own warning). Lowering `radiance.max_num_seqs` below 8 would free per-sequence state for more cache, at the cost of fewer concurrent requests per instance; not measured.

### Two-GPU split (TP2) was not run

The Radiance issue tracker (read 2026-11-07) has open reports of TP2 wedging both cards on 2x R9700: #409 (stock 1.16.0 wedges within 2 to 10 minutes; stock 1.17.0 wedged permanently at about 6 minutes, twice; `--p2p off` does not avoid it; both wires affected; unmerged patches proposed), #415 (a card reset froze the machine) and #356. There is no watchdog flag, and I have no sudo to reset a GPU, so I did not run TP2 without your explicit go-ahead and a reboot available.

### Quality, VRAM, power, startup, stability

| | llama.cpp split | Radiance (TP1) |
|---|---|---|
| Tool-call test (8 prompts x 5, thinking off, exact tool names and required args) | 35/40 | 35/40 no spec, 35/40 spec |
| Where it failed | "replace foo_old with foo_new" (0/5, called `grep` first) | same prompt, same behaviour |
| Vision (red 128x128 PNG, "what color") | not tested, server had no mmproj (HTTP 500) | "Red" in both modes |
| VRAM | 28.8 GiB on one GPU in the single-GPU bench; split-run VRAM not captured | 34.05 of 34.2 GB on the chosen GPU. Radiance sizes a 15.95 GiB KV pool and takes the rest, so this is allocation, not need. |
| Power (one sample window each) | about 293 to 298 W on the busy GPU (first 2 s only, the sampler stopped) | peak 329 W on the busy GPU |
| Startup, model in page cache | 12 s | 13 to 15 s (image already pulled) |
| First download | n/a | 639 MB image, 19.4 GB model, about 30 min at 10 MB/s |
| Hangs, GPU resets, errors | none seen | none seen. 0 error/fatal/reset/hang lines in four container logs, and no amdgpu reset or fault in the kernel log for the window. |

What the quality checks do and do not cover: 40 simple tool prompts and one colour image. They do not cover your real prompts, long agent loops, code correctness, or whether speculation changes outputs. The vllm-radiance README says speculation matched non-spec output on only 1 of 8 fixed prompts, which may be harmless numeric drift or may not. I did not compare outputs.

Not tested: TP2 or any two-GPU Radiance (deliberately, because of the open hang reports), a soak run longer than a few minutes, the Qwen3.6-27B model, Radiance under concurrent load from your real agents, and P2P between the two cards.

Measurement caveats: one run per cell for the long tests, run-to-run spread for the short test is in the ranges above, power was sampled with a loop that died early for the llama.cpp runs, and the first launch of the baseline script was killed by a session cleanup and relaunched with the finished GPU 0 bench skipped (its numbers are from the first run).

## (d) Recommendation

Run alongside. Do not switch yet.

What the data supports: on this machine Radiance TP1 is clearly faster than llama.cpp Vulkan on the same Qwen3.8-27B, and that holds against llama.cpp with MTP speculation too. Prefill is 4 to 8 times faster, which matters most for tool-heavy agents with long contexts (a 100k prompt: 54 s vs 199 s plain llama.cpp vs 409 s with MTP). Under four concurrent requests Radiance keeps 31 tok/s per stream without speculation (about 75 with it) while llama.cpp falls to 13 to 15 either way, and first token at c4 drops from 35 to 46 s to 3 to 4 s. For a single stream the gap is smaller than my first round suggested: llama.cpp + MTP decodes 61 tok/s on short tool calls and 48 on code, against Radiance's 40 and 27 without speculation, and 189 and 145 with it. One card holds the full 262144 context (two retrieval tests passed), so a TP2 split is not needed for context length. It started cleanly under rootless podman on Bazzite, showed no GPU errors, handled a 100k prompt, and passed the same tool-call and vision checks I could run.

Why I did not call this "no compromises" and did not change your live services:

- Quality is unproven. MXFP4 vs Q8_0 and speculation vs not were not compared on output quality, and the tool-call test is small. An open issue (#382) reports parallel tool calls with thinking off dropping from about 80% to about 20% in release 1.16.0. This test did not reproduce that on 1.17.0, but 8 prompts is not enough to rule it out.
- Stability is unproven beyond minutes. Upstream releases about daily, and two quality regressions were reported in a month. Pin the image tag.
- Radiance takes a whole GPU (it sized its KV pool to fill the card). That is fine for TP1 on GPU A, but it means the combined-VRAM 262144-context `-big` setup and Radiance cannot share a card.
- The model format is different (`.rad`, no GGUF), so new weights and a separate model directory.
- Two-GPU Radiance (TP2) is still the part with open hang reports, and your two cards are connected differently (one behind the chipset at PCIe 4.0 x4). I did not test it. TP1 per GPU avoids it.

Suggested split: Radiance TP1 on GPU A (port 1237) for the Pi and Cline agents, and keep llama.cpp on GPU B (port 1235, or the single-GPU config) for GGUF models, vision with mmproj, and as a fallback. Before relying on it: run your real tool-calling prompts through both with spec on and off, and run a few hours of agent traffic while watching `logs-rad`.

If upstream closes the TP2 hang issues and someone independent reproduces the numbers, revisit TP2 and a single Radiance instance across both cards.

## (e) LLaMesa backend abstraction

### What is built and deployed

Server side, in `server/llamesa.sh`: an opt-in command family beside `-big` and `-dual`, following their convention of fully independent commands. One TP1 container per GPU, same model and settings on each; instances are keyed `r9700a` and `r9700b` like `-dual`.

| Command | What it does |
|---|---|
| `list-models-rad` | JSON list of `*.rad` files in `radiance.models_dir`, same fields as `list-models` plus `"backend":"radiance"` |
| `start-rad --model N [--thinking on/off] [--ctx N] [--parallel N] [--gpu r9700a\|r9700b\|0\|1]` | starts every configured instance (or the one named by `--gpu`) in rootless podman with `--served-model-name <name>-a/-b`, waits for `/health` on all of them, writes a session file per instance. Refuses if the RAM or port checks fail; if one instance fails to start it stops the others. |
| `stop-rad [--gpu K]`, `restart-rad [--gpu K]` | `podman stop` and `rm` with timeouts; restart restores each instance's remembered model, context, thinking and parallel settings |
| `status-rad [--gpu K]` | one object for a single instance, an array for several (the `status-dual` convention), each with `gpu_id`, `name`, port, and only its own GPU's VRAM in `devices` |
| `logs-rad --gpu K` | `podman logs -f`; refuses without `--gpu` when several instances are configured |

Config is a `radiance` block (example in `config/server.example.json`) with `instances`, `served_model_name`, `models_dir`, `speculative`, `kv_cache_dtype`, `max_num_seqs` and `extra_args`. `radiance.tp` must be 1: any other value is refused, because two-GPU Radiance wedges on 2x R9700 upstream. Without an `instances` block the script uses one instance on `radiance.gpu` and `radiance.port`, so the first single-instance config keeps working. The only change outside the `-rad` block is that `LLAMESA_DIR` can be overridden by the environment (default unchanged) and `--gpu` is also remembered as "given", which `-rad` needs because the default is 0.

Deployed on the host on 2026-11-07 on top of the live script (which is ahead of this branch, see below). `--thinking off` relies on Radiance's `--chat-template-kwargs` flag, which the docs describe only in a section I could not read verbatim; it worked in every test.

### Client (built and deployed)

`client/llamesa.ps1` has a fourth mode, `rad`, that reuses the combined-VRAM code paths, so the existing modes are untouched:

| Piece | Change |
|---|---|
| `/start` | Radiance on the first GPU, main port 1234: pick a `.rad` model, thinking on/off, context (262144 suggested), optional parallel sequences; calls `start-rad --gpu r9700a` |
| `/start-2nd` | Radiance on the second GPU, port 1235. When the first GPU is running, the default is "same as the first" (`start-rad --gpu r9700b --like r9700a`); otherwise the full picker |
| `/start-big` | llama.cpp across both GPUs (port 1236); refuses while Radiance runs |
| `/start-llama` | the original llama.cpp start flow (one model across both GPUs, or one per GPU) |
| `/engine` (new palette command) | switches which running engine the client follows (Radiance, llama.cpp combined VRAM, one-per-GPU, single-GPU). Needed because Radiance can run next to a llama.cpp server and the client tracks one mode at a time |
| `/stop` | lists each running Radiance instance as a target (with "Both") and calls `stop-rad --gpu K` |
| `/restart` | in `rad` mode calls `restart-rad --gpu K` for each running instance |
| `/health`, `/logs`, `/models`, `/servers` | follow `rad` mode: both ports, `logs-rad --gpu K`, `list-models-rad`, `rad:r9700a:1237, r9700b:1238` |
| Dashboard header | `Show-HeaderBig -Radiance` with both GPU bars, "model x2", both ports and a "radiance · 2 GPUs" pill |
| Chat | follows `rad` mode; with two instances running it asks which one to talk to; the streaming code is unchanged |
| Status polling and startup | `rad` mode polls `status-rad`; startup adopts running Radiance instances |

Tests: the file parses with the PowerShell parser, and 40 offline checks with a mocked server pass (instance counting including the stopped-array case, startup detection, one- and two-instance headers, start with and without `--gpu`, health targets, chat instance choice, stop one vs both, restart, `/engine`, model-loaded). A live run through the deployed client on the real host started both instances in 24 s, drew the two-GPU header, passed `/health` on both ports, streamed a chat answer from each instance over the network (100 and 130 tok/s on short replies), and stopped both. I did not drive the interactive terminal screen by hand, so cosmetic issues in the live TUI are still possible.

Known limits: if Radiance and a llama.cpp single-GPU server both run, the dashboard header shows only the engine selected with `/engine`. `/start-rad` has no context suggestion (a `.rad` file has no GGUF header), so leaving context blank uses the server default of 131072.

### Port plan

Ports belong to a GPU slot, not to an engine: 1234 is the first GPU, 1235 the second, 1236 llama.cpp across both. A GPU holds one server at a time, so the numbers can be shared by Radiance and llama.cpp without a clash. This needed a fix in the llama.cpp status checks: they treated any listening port as a llama.cpp server, so Radiance on 1234 or 1235 showed up as a running llama.cpp instance and `/stop` sent its stop to the wrong place (found in the first live run). Four checks in the host script now ignore a port that a running Radiance container owns. `start-rad` also refuses when `-big` runs or when another process holds more than 2 GiB of VRAM on the target GPU.

Live run through the deployed client (2026-11-07, after the fix): `/start` came up on 1234 (ctx 262144), `/start-2nd` on 1235 with the same model, context and thinking setting, both answered chat, llama.cpp's dual and single views showed nothing running while Radiance ran, `/start-big` refused while Radiance ran, `/stop` stopped both, `/start-big` loaded Qwen3.8-27B GGUF on 1236 and answered chat, `/start` refused while llama.cpp ran, and after `/stop` `/start` came back on 1234 again.

### Not built

- One shared port for both instances. The model name in a request is not enforced by Radiance, so a proxy would have to route by something else, and for coding it must keep each conversation on one GPU (each instance keeps its own cache of finished conversations, so alternating requests would redo the whole prompt). Two ports with one port per agent works today.
- Pre-flight VRAM check: `start-rad` only warns if something listens on 1234 to 1236. It does not check which GPU a llama.cpp server holds.
- `/download` for `.rad` files (the Hugging Face fetch needs a different file pattern).
- A way to pass `--rope-scaling` through `start-rad` other than `radiance.extra_args`.
- The old llama.cpp one-per-GPU modes (`start`, `start-dual`) share ports 1234 and 1235 with Radiance and were not re-tested beyond the status checks.

### Shared and unchanged

SSH transport and `Invoke-ServerCommand`, the status poll loop, TUI rendering, model picker UI, `/chat`, session JSON files, port bookkeeping, RAM safety check (reused by `start-rad`).

### Install and rollback

Going back to llama.cpp was verified on 2026-11-07 after Radiance had been deployed: `start-big --model Qwen3.8-27B-GGUF --thinking on --ctx 262144` through the deployed script was healthy 12 s after launch, answered a chat request, and `stop-big` left no listeners or `llama-server` processes. `big_session.json` was byte-identical afterwards. One existing quirk: `start-big` prints "ready" as soon as port 1236 answers with any HTTP status, including 503 while the model is still loading, so poll `/health` for 200 before sending requests.

Install (already done on the host): copy `server/llamesa.sh` to the host, add the `radiance` block to `~/.llamesa/config.json`, `podman pull` the pinned image, download the `.rad` into `radiance.models_dir`. Rollback: `llamesa.sh stop-rad`, delete the `radiance` block and the models directory, `podman rmi` the image, restore the previous `llamesa.sh` (the host keeps timestamped `.bak` copies; make one first).

## What was changed on the host and the Windows client (2026-11-07)

Additive and reversible. Backups use a timestamp suffix.

- Host `~/.llamesa/llamesa.sh`: the live script plus the `-rad` block. Backups: `llamesa.sh.bak-20261107-064722` (before Radiance) and `llamesa.sh.bak-20261107-080226-rad1` (single-instance version), and later `-rad2`, `-rad3`, `-rad4` suffixes for the default-context, slot-command and port-ownership revisions.
- Host `~/.llamesa/config.json`: a `radiance` block with two instances (ports 1234 and 1235 since the port plan; they were 1237 and 1238 during the earlier tests above). Backups: `config.json.bak-20261107-064722` and `config.json.bak-20261107-080226-rad1`.
- Windows `~/.llamesa/llamesa.ps1`: the version with `rad` mode. Backups: `llamesa.ps1.bak-20261107-064740` and `llamesa.ps1.bak-20261107-080227-rad1`.
- Host `/var/mnt/games/models-radiance/qwen3.8-27b-mxfp4.rad` (19.4 GB) and the podman image `docker.io/stilldeadcode/radiance:1.17.0` (639 MB).
- Host `~/radiance-eval/` holds scripts, logs, throwaway configs and a second 19 GB copy of the model that can be deleted.
- Nothing is running. Ports 1234 to 1236 were used only by the `start-big` go-back check (the same server you run normally, same settings, `big_session.json` unchanged afterwards).
- No sudo, no system files, no live service left changed.
- The repo's `server/llamesa.sh` is the repo's older base plus the `-rad` block. The host's script is the live script (which has the KV-cache and speculative-decoding options from commit 5cd45a3, on another branch) plus the same block, so the two files differ outside `-rad` until those branches are merged.

## Open items

1. The repo changes are uncommitted.
2. Not tested: TP2 (documented to wedge on this hardware), hours of sustained load, a real Pi or Cline session, quality of MXFP4 and of speculation against your usual prompts, a shared single port with sticky routing.
3. Optional: send two or three of your real tool-calling prompts or a captured session so I can compare outputs with speculation on and off, and Q8_0 against MXFP4.

## Sources

- [Level1Techs thread 258397](https://forum.level1techs.com/t/258397)
- [Radiance](https://codeberg.org/StillDeadcode/radiance), [tags](https://codeberg.org/StillDeadcode/radiance/tags), [issues](https://codeberg.org/StillDeadcode/radiance/issues)
- [libr4d](https://codeberg.org/StillDeadcode/libr4d) (marked outdated by its author, moved into radiance)
- [Docker Hub stilldeadcode/radiance](https://hub.docker.com/r/stilldeadcode/radiance)
- [magiccodingman/vllm-radiance](https://github.com/magiccodingman/vllm-radiance)
- [christopherpaquin/Radiance-vLLM-AMD-R9700](https://github.com/christopherpaquin/Radiance-vLLM-AMD-R9700)
- [13pgeiser/rdna4_engines](https://github.com/13pgeiser/rdna4_engines)
- Level1Techs video: https://youtu.be/Ty4lTwykmKY (not watched; it was described as having no numbers)
