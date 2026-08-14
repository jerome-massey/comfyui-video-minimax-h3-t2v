# video_minimax_h3_t2v

MiniMax H3 **text-to-video with native stereo audio**, packaged as a Runpod Serverless worker.

Validated end to end on an A40 (Ampere, 48 GB) — 864x480, 5.17 s, h264 + stereo AAC,
576 s per generation.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Serverless worker image: ComfyUI v0.30.0 + H3 models |
| `api-workflow.json` | The `/prompt` payload — 17 nodes, emitted by ComfyUI itself |
| `workflow.json` | The editable graph (uses a subgraph; load this in the ComfyUI UI) |

## Calling the endpoint

`api-workflow.json` goes inside an `input.workflow` envelope:

```json
{ "input": { "workflow": { ...contents of api-workflow.json... } } }
```

### Parameters worth overriding

| Node | Field | Notes |
|---|---|---|
| `105:104` | `prompt` | Describe shots, camera moves **and** audio in one block |
| `105:104` | `length` | Frame count — see the grid rule below |
| `105:15` | `noise_seed` | Change per request or every call returns the same video |
| `115` | `megapixels` | 0.4 = 864x480. Raising this risks OOM — see VRAM below |

### The frame-count grid

H3 only accepts lengths on a **17k+5** grid at 24 fps. The graph derives this from a
duration via `ComfyMathExpression`, but API callers should compute it directly:

```
length = max(5, round(seconds * 24))
length = length + (5 - (length % 17)) % 17
```

5 s -> 124 frames (17x7+5) -> 5.167 s of video.

## Why these specific model builds

The text encoder is **`int8_convrot`**, not `nvfp4_awq`.

Runpod Serverless selects by VRAM tier, not GPU model. The 48 GB tier spans Ampere
(A40, RTX A6000) and Ada (L40, L40S), and you cannot pin the architecture. NVFP4 is
Blackwell-native; on Ampere and Ada it only emulates. ComfyUI reports this directly
at load time:

```
Native ops: int8_tensorwise, convrot_w4a4 , emulated ops: nvfp4, float8_e4m3fn, ...
```

`int8_convrot` runs natively on every card in the tier. Use `nvfp4_awq` only if you
pin a Blackwell-guaranteed tier (96 GB PRO).

## VRAM

Peak **39.5 GB of 46 GB usable** on an A40 at 864x480 / 124 frames — about 86%.
ComfyUI loads the text encoder, encodes, frees it, then loads the diffusion model,
which is what keeps 46 GB of weights inside a 48 GB card. Higher `megapixels` values
(the graph's notes list presets up to 1920x1088) will OOM on a 48 GB card.

## Timing

| Phase | Duration |
|---|---|
| Model load (cold worker) | ~75 s |
| Sampling, 20 steps @ 18.5 s/it | ~500 s |
| **Total** | **~576 s** |

Sampling dominates, so reducing `steps` saves far more than optimising model loading.

## Build it yourself

```bash
docker build -t minimax-h3-t2v .
```

The image is large (~55 GB) because the four model files total 51 GB. For several
endpoints sharing these weights, move the models to a Runpod network volume mounted
at `/runpod-volume/models/` and drop the download layers instead.

## Known-good versions

- ComfyUI **v0.30.0** — first release containing `comfy_extras/nodes_minimax_h3.py`
  (PR Comfy-Org/ComfyUI#15224, merged 2026-08-03). `worker-comfyui` pins 0.29.0,
  which does **not** have the H3 nodes; the Dockerfile upgrades it.
- Base image `runpod/worker-comfyui:5.8.7-base` — supplies `/handler.py` and `/start.sh`.

If Runpod's repo scanner warns that `runpod.serverless.start()` is missing, ignore it.
The handler lives in the base image, which the scanner cannot see into.
