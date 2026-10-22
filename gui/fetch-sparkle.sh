#!/bin/zsh
# Downloads the pinned Sparkle release once, checks it, and prints where it is.
set -eu

version=2.10.0
sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
sparkle="$root/build/Sparkle-$version"

if [[ ! -d $sparkle/Sparkle.framework ]]; then
  work="$(mktemp -d "${TMPDIR:-/tmp}/sparkle.XXXXXX")"
  trap 'rm -rf "$work"' EXIT
  curl -fsSL -o "$work/Sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
  print -r -- "$sha256  $work/Sparkle.tar.xz" | shasum -a 256 -c --quiet
  mkdir "$work/Sparkle"
  tar -xJf "$work/Sparkle.tar.xz" -C "$work/Sparkle"
  mkdir -p "$root/build"
  rm -rf "$sparkle"
  mv "$work/Sparkle" "$sparkle"
fi
print -r -- "$sparkle"
