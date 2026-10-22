#!/bin/zsh
# Regenerate the macOS icon family from the full-resolution logo.
set -eu

source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/sleep-in-icon.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
iconset="$work_dir/SleepIn.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_dir/Resources/SleepIn.png" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$source_dir/Resources/SleepIn.png" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$source_dir/Resources/SleepIn.icns"
print -r -- "Built $source_dir/Resources/SleepIn.icns"
