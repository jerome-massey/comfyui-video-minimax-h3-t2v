# MiniMax H3 text-to-video — Runpod Serverless worker
#
# Base gives us ComfyUI + comfy-cli + the Runpod handler (/handler.py, CMD /start.sh).
# NOTE: worker-comfyui pins ComfyUI 0.29.0, which predates MiniMax H3 support.
# H3 landed in ComfyUI v0.30.0 (PR Comfy-Org/ComfyUI#15224, merged 2026-08-03),
# so we upgrade the checkout below. 0.30.0 is pinned deliberately: it is the exact
# version the workflow was authored on and validated against on an A40.
FROM runpod/worker-comfyui:5.8.7-base

ARG COMFYUI_VERSION=v0.30.0
ARG HF_TOKEN=""

# --- Upgrade ComfyUI to a release that contains comfy_extras/nodes_minimax_h3.py ---
RUN cd /comfyui \
 && git fetch --depth 1 origin refs/tags/${COMFYUI_VERSION}:refs/tags/${COMFYUI_VERSION} \
 && git checkout ${COMFYUI_VERSION} \
 && pip install --no-cache-dir -r requirements.txt \
 && test -f comfy_extras/nodes_minimax_h3.py \
      || (echo "FATAL: MiniMax H3 nodes missing after upgrade to ${COMFYUI_VERSION}" >&2; exit 1)

# --- Models ---
# Each file goes into the directory ComfyUI actually scans. The generated
# Dockerfile used models/Unknown, which ComfyUI never indexes, so the loaders
# came up empty even though the weights were on disk.
#
# Text encoder is int8_convrot, NOT nvfp4_awq. Runpod Serverless assigns any card
# in the selected VRAM tier, and the 48GB tier spans Ampere (A40, A6000) as well as
# Ada (L40, L40S). NVFP4 is Blackwell-native and only emulates on those cards —
# ComfyUI reports "Native ops: int8_tensorwise, convrot_w4a4 , emulated ops: nvfp4".
# int8_convrot runs natively on every card in the tier.

ENV HF_HUB_ENABLE_HF_TRANSFER=1
RUN pip install --no-cache-dir hf_transfer

RUN set -eux; \
    M=/comfyui/models; \
    for spec in \
      "vae/minimax_h3_video_vae_fp16.safetensors" \
      "vae/minimax_h3_audio_vae_fp32.safetensors" \
      "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors" \
      "text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors" \
    ; do \
      for attempt in 1 2 3 4 5; do \
        HF_TOKEN="$HF_TOKEN" hf download Comfy-Org/MiniMax-H3 "$spec" --local-dir "$M" && break; \
        [ "$attempt" = 5 ] && { echo "model download failed: $spec" >&2; exit 1; }; \
        sleep $((attempt * 15)); \
      done; \
    done; \
    rm -rf "$M/.cache"

# Fail the build rather than ship an image whose loaders will come up empty.
RUN test -s /comfyui/models/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors \
 && test -s /comfyui/models/text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors \
 && test -s /comfyui/models/vae/minimax_h3_video_vae_fp16.safetensors \
 && test -s /comfyui/models/vae/minimax_h3_audio_vae_fp32.safetensors
