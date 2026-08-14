#!/usr/bin/env bash
# One-time population of the Runpod network volume with the four H3 weights.
#
# Not part of the normal worker path — /start.sh is. Run this by pointing a
# throwaway endpoint's start command at it with the volume attached, or from a
# pod that mounts the volume. Safe to re-run: hf download resumes and skips
# files that are already complete.
set -euo pipefail

M="${MODELS_DIR:-/runpod-volume/models}"
REPO=Comfy-Org/MiniMax-H3

if [ ! -d "$(dirname "$M")" ]; then
  echo "FATAL: $(dirname "$M") does not exist — is the network volume attached?" >&2
  exit 1
fi

export HF_HUB_ENABLE_HF_TRANSFER=1
mkdir -p "$M"

# Paths are relative to the repo root and are reproduced verbatim under $M,
# which is why they line up with extra_model_paths.yaml without any moves.
FILES="
vae/minimax_h3_video_vae_fp16.safetensors
vae/minimax_h3_audio_vae_fp32.safetensors
diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors
text_encoders/qwen3vl_32b_minimax_h3_int8_convrot.safetensors
"

for spec in $FILES; do
  echo "=== fetching $spec"
  for attempt in 1 2 3 4 5; do
    if hf download "$REPO" "$spec" --local-dir "$M"; then
      break
    fi
    if [ "$attempt" = 5 ]; then
      echo "FATAL: download failed after 5 attempts: $spec" >&2
      exit 1
    fi
    sleep $((attempt * 15))
  done
done

rm -rf "$M/.cache"

# Fail loudly rather than leave a volume that yields empty loaders.
for spec in $FILES; do
  if [ ! -s "$M/$spec" ]; then
    echo "FATAL: missing or empty after download: $M/$spec" >&2
    exit 1
  fi
done

echo "=== volume contents"
du -sh "$M"/*/* 2>/dev/null || true
df -h "$M" | tail -1
echo "FETCH_MODELS_COMPLETE"

# Hold the worker open so the logs above stay readable and the container is not
# restarted into a redundant second pass. Delete the loader endpoint when done.
sleep infinity
