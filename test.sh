#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT_DIR/.build"

swiftc \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  "$ROOT_DIR/Sources/Wispry/TranscriptAccumulator.swift" \
  "$ROOT_DIR/Sources/Wispry/SettingsStore.swift" \
  "$ROOT_DIR/Sources/Wispry/TextPipeline.swift" \
  "$ROOT_DIR/Tests/TextPipelineSmoke.swift" \
  -o "$ROOT_DIR/.build/TextPipelineSmoke"

"$ROOT_DIR/.build/TextPipelineSmoke"
