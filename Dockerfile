# MiniMax H3 text-to-video — Runpod Serverless worker
#
# Base gives us ComfyUI + comfy-cli + the Runpod handler (/handler.py, CMD /start.sh).
# NOTE: worker-comfyui pins ComfyUI 0.29.0, which predates MiniMax H3 support.
# H3 landed in ComfyUI v0.30.0 (PR Comfy-Org/ComfyUI#15224, merged 2026-08-03),
# so we upgrade the checkout below. 0.30.0 is pinned deliberately: it is the exact
# version the workflow was authored on and validated against on an A40.
FROM runpod/worker-comfyui:5.8.6-base

ARG COMFYUI_VERSION=v0.30.0

# --- Upgrade ComfyUI to a release that contains comfy_extras/nodes_minimax_h3.py ---
# comfy-cli installs ComfyUI by cloning into /comfyui, so this is a git checkout.
# PATH already points at the base image's venv (/opt/venv/bin), so pip is the
# venv's pip and the upgraded requirements land where ComfyUI actually runs.
#
# The torch lines are filtered out of requirements.txt only to stop pip pulling a
# wheel that the next step immediately replaces. `torchsde` is not matched.
RUN cd /comfyui \
 && git fetch --depth 1 origin refs/tags/${COMFYUI_VERSION}:refs/tags/${COMFYUI_VERSION} \
 && git checkout ${COMFYUI_VERSION} \
 && grep -viE '^(torch|torchvision|torchaudio)[[:space:]]*$' requirements.txt > /tmp/req-no-torch.txt \
 && pip install --no-cache-dir -r /tmp/req-no-torch.txt \
 && test -f comfy_extras/nodes_minimax_h3.py \
      || (echo "FATAL: MiniMax H3 nodes missing after upgrade to ${COMFYUI_VERSION}" >&2; exit 1)

# --- Put torch back on CUDA 12 ---
# The base image ships torch 2.12.0+cu130 despite being built FROM a CUDA 12.8
# image. A cu130 build refuses to initialise on a Runpod host whose driver
# reports CUDA 12.6, and US-TX-3 hands out exactly those:
#
#   FAIL: The NVIDIA driver on your system is too old (found version 12060)
#
# start.sh treats that as fatal, so the worker crash-loops before the handler
# ever runs and jobs sit IN_QUEUE looking like a capacity shortage.
#
# cu126 rather than cu128: a CUDA 12.6 build runs on 12.6, 12.8 and 13.0 drivers
# alike, so it widens the pool of eligible hosts instead of narrowing it — which
# matters because the network volume already pins this endpoint to one
# datacenter. The versions are the same ones the base image had, so this is a
# rebuild against an older CUDA rather than a downgrade of torch itself.
# (torchaudio 2.11.0 is the newest that exists on any index, cu130 included.)
#
# The +cu126 local version is required, not decoration. PEP 440 ignores the
# local segment when matching, so `torch==2.12.0` is satisfied by the installed
# 2.12.0+cu130 and pip reports "Requirement already satisfied" and changes
# nothing — the build then still ships a CUDA 13 stack.
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu126 \
      torch==2.12.0+cu126 torchvision==0.27.0+cu126 torchaudio==2.11.0+cu126

# Catch a CUDA-13 torch at build time rather than as a crash-looping worker.
RUN python -c "import torch, torchvision, torchaudio; \
print('torch', torch.__version__, 'torchvision', torchvision.__version__, 'cuda', torch.version.cuda); \
assert torch.version.cuda and torch.version.cuda.startswith('12.'), \
  'expected a CUDA 12.x torch, got ' + str(torch.version.cuda)"

# --- Point ComfyUI at the volume, and ship the one-time populator ---
# extra_model_paths.yaml overwrites the base image's copy. ComfyUI reads it
# automatically from its base directory, and start.sh never regenerates it.
COPY extra_model_paths.yaml /comfyui/extra_model_paths.yaml
COPY fetch-models.sh /fetch-models.sh
RUN chmod +x /fetch-models.sh \
 && pip install --no-cache-dir "huggingface_hub[hf_transfer]>=0.34"

# --- Models are NOT baked into this image ---
# The four H3 files total 51 GB. Baking them in produced a ~55 GB image, which
# has to be pulled in full onto every new worker machine and cannot be built on
# a free CI runner. They live on a Runpod network volume instead, mounted at
# /runpod-volume, which keeps this image around 12 GB.
#
# Expected volume layout, which is just the Comfy-Org/MiniMax-H3 repo structure
# reproduced under models/ — see extra_model_paths.yaml:
#
#   /runpod-volume/models/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors
#   /runpod-volume/models/text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors
#   /runpod-volume/models/vae/minimax_h3_video_vae_fp16.safetensors
#   /runpod-volume/models/vae/minimax_h3_audio_vae_fp32.safetensors
#
# Run /fetch-models.sh once with the volume attached to create it.
#
# Text encoder is int8_convrot, NOT nvfp4_awq. NVFP4 is Blackwell-native and only
# emulates on Ampere and Ada — ComfyUI reports "Native ops: int8_tensorwise,
# convrot_w4a4 , emulated ops: nvfp4" at load time. int8_convrot runs natively on
# both 48 GB pools (AMPERE_48 and ADA_48_PRO), so the endpoint is not locked to
# one architecture.
#
# See README.md for the one-time volume population steps.
