#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repo/tool/com.mxjxn.RenoiseOscSequencer.xrnx"
output="$repo/dist/Renoise-Osc-Sequencer.xrnx"
mkdir -p "$repo/dist"
rm -f "$output"
(cd "$source_dir" && zip -q -r "$output" manifest.xml main.lua README.md)
echo "$output"
