#!/bin/bash
# Download WhisperKit models and place them in WhisperModels/ for app bundling.
# Models are bundled as folder references and loaded from the app bundle at runtime.
#
# Usage:
#   ./download_models.sh              # Download all models
#   ./download_models.sh tiny base    # Download specific models only
#
# Requires: huggingface-cli (pip install huggingface-hub)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/WhisperModels"
REPO="argmaxinc/whisperkit-coreml"

ALL_MODELS=(
    "openai_whisper-tiny"
    "openai_whisper-base"
    "openai_whisper-small"
    "openai_whisper-medium"
    "openai_whisper-large-v3_turbo"
    "distil-whisper_distil-large-v3_turbo"
)

# If arguments given, use those; otherwise download all
MODELS=("${@:-${ALL_MODELS[@]}}")

# Check for huggingface-cli
if ! command -v huggingface-cli &> /dev/null; then
    echo "huggingface-cli not found. Install with: pip install huggingface-hub"
    exit 1
fi

mkdir -p "$MODELS_DIR"

for model in "${MODELS[@]}"; do
    target_dir="$MODELS_DIR/$model"
    if [ -d "$target_dir" ]; then
        echo "[$model] Already exists, skipping. Delete $target_dir to re-download."
        continue
    fi

    echo "[$model] Downloading..."
    hf download "$REPO" --include "$model/*" --local-dir "$MODELS_DIR"
    echo "[$model] Done."
done

echo ""
echo "All models downloaded to: $MODELS_DIR"
echo "Model sizes:"
du -sh "$MODELS_DIR"/* 2>/dev/null || true
echo ""
echo "Total size:"
du -sh "$MODELS_DIR"
