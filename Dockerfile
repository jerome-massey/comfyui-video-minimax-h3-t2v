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
RUN cd /comfyui \
 && git fetch --depth 1 origin refs/tags/${COMFYUI_VERSION}:refs/tags/${COMFYUI_VERSION} \
 && git checkout ${COMFYUI_VERSION} \
 && pip install --no-cache-dir -r requirements.txt \
 && test -f comfy_extras/nodes_minimax_h3.py \
      || (echo "FATAL: MiniMax H3 nodes missing after upgrade to ${COMFYUI_VERSION}" >&2; exit 1)

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
