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

Runpod splits 48 GB into two selectable pools — `AMPERE_48` (A40, RTX A6000) and
`ADA_48_PRO` (L40, L40S, RTX 6000 Ada) — so the architecture *can* be pinned. It
still should not be pinned to Blackwell-only for this reason: NVFP4 is
Blackwell-native and merely emulates on both of these pools. ComfyUI reports this
directly at load time:

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

## Deploying

The weights are **not** in the image. They live on a Runpod network volume, which
keeps the image around 12 GB instead of 55 GB — small enough to build on a free CI
runner, and not re-pulled onto every new worker machine.

### 1. Image

Pushing to `main` builds `ghcr.io/jerome-massey/comfyui-video-minimax-h3-t2v:latest`
via `.github/workflows/build.yml`. The GHCR package must be **public**, or the
endpoint needs a container registry credential to pull it.

### 2. Volume

Create a network volume of at least 60 GB, then populate it once by pointing a
throwaway endpoint's start command at `/fetch-models.sh` with the volume attached.
The script is idempotent, so a re-run only fills in what is missing.

The layout it produces is the `Comfy-Org/MiniMax-H3` repo structure verbatim:

```
/runpod-volume/models/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors
/runpod-volume/models/text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors
/runpod-volume/models/vae/minimax_h3_video_vae_fp16.safetensors
/runpod-volume/models/vae/minimax_h3_audio_vae_fp32.safetensors
```

`extra_model_paths.yaml` names those categories directly. The base image's own copy
uses the legacy `unet:`/`clip:` keys instead — which do resolve, since
`add_model_folder_path()` maps `unet`→`diffusion_models` and `clip`→`text_encoders`,
but they'd force the volume into directory names that match nothing upstream.

### 3. Endpoint

A network volume is tied to one datacenter and pins the endpoint with it, so the
volume's datacenter has to be one that actually has 48 GB stock. That is a real
constraint: **CA-MTL-1 and EU-SE-1 have the best 48 GB availability but support no
network volumes at all.** The datacenters where both are possible are CA-MTL-3
(`AMPERE_48`), and US-IL-1, US-TX-3 and EU-NL-1 (`ADA_48_PRO`).

## Known-good versions

- ComfyUI **v0.30.0** — first release containing `comfy_extras/nodes_minimax_h3.py`
  (PR Comfy-Org/ComfyUI#15224, merged 2026-08-03). `worker-comfyui` pins 0.29.0,
  which does **not** have the H3 nodes; the Dockerfile upgrades it.
- Base image `runpod/worker-comfyui:5.8.6-base` — supplies `/handler.py` and
  `/start.sh`. Note 5.8.7 does **not** exist; an earlier revision of this repo
  pinned it and could never have built.

If Runpod's repo scanner warns that `runpod.serverless.start()` is missing, ignore it.
The handler lives in the base image, which the scanner cannot see into.
