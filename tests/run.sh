#!/bin/zsh
# Builds and runs the test programs. Nothing here changes power settings or asks for a password.
set -eu

root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/sleep-in-tests.XXXXXX")"
trap 'rm -rf "$build"' EXIT
flags=(-swift-version 5 -target arm64-apple-macosx14.0)

# Optimized like the shipped command; these checks don't rely on assert().
xcrun swiftc -O "${flags[@]}" "$root"/cli/{System,Timer,LidSession,Command}.swift "$root/tests/TimerTests.swift" -o "$build/timer-tests"
xcrun swiftc "${flags[@]}" "$root/gui/LidSleepPolicy.swift" "$root/tests/LidSleepPolicyTests.swift" -o "$build/policy-tests"
"$build/timer-tests"
"$build/policy-tests"
