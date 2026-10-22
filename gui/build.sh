#!/bin/zsh
set -eu

source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
installed="$HOME/Applications/Sleep In.app"
daemon_label="io.github.qwertyu-alex.sleep-in.lid-daemon"
version="${SLEEP_IN_VERSION:-1.0.0}"
# SLEEP_IN_OUTPUT builds into that directory instead of installing, for releases.
output="${SLEEP_IN_OUTPUT:-}"
if [[ -n $output ]]; then
  staging="$output"
else
  mkdir -p "$HOME/Applications"
  # Build beside the installed app, then swap it in whole; a running timer keeps its loaded copy.
  staging="$(mktemp -d "$HOME/Applications/.sleep-in-build.XXXXXX")"
  trap 'rm -rf "$staging"' EXIT
fi
app_dir="$staging/Sleep In.app"

# Lid-closed mode's root daemon only trusts code signed by the same Developer ID team.
identity="${SLEEP_IN_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning |
  sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -n 1)}"
if [[ -z $identity ]]; then
  print -u2 "No Developer ID Application certificate found. Install one in your login keychain,"
  print -u2 "or set SLEEP_IN_SIGNING_IDENTITY to the signing identity to use."
  exit 1
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Library/LaunchDaemons"
cp "$source_dir/Resources/SleepIn.icns" "$app_dir/Contents/Resources/SleepIn.icns"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  "$source_dir/LidSleepPolicy.swift" "$source_dir/LidAwakeService.swift" "$source_dir/LidAwakeDaemon.swift" \
  -o "$app_dir/Contents/MacOS/SleepInLidDaemon"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  "$source_dir/LidAwakeService.swift" "$source_dir/LidAwakeClient.swift" \
  -o "$app_dir/Contents/MacOS/SleepInLidClient"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  "$source_dir"/../cli/*.swift -o "$app_dir/Contents/MacOS/sleep-in"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  "$source_dir/SleepIn.swift" -o "$app_dir/Contents/MacOS/SleepIn"

cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SleepIn</string>
  <key>CFBundleIdentifier</key><string>io.github.qwertyu-alex.sleep-in</string>
  <key>CFBundleName</key><string>Sleep In</string>
  <key>CFBundleDisplayName</key><string>Sleep In</string>
  <key>CFBundleIconFile</key><string>SleepIn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Registered by the app with SMAppService; launchd starts it on demand.
cat > "$app_dir/Contents/Library/LaunchDaemons/$daemon_label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$daemon_label</string>
  <key>BundleProgram</key><string>Contents/MacOS/SleepInLidDaemon</string>
  <key>MachServices</key><dict><key>$daemon_label</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>io.github.qwertyu-alex.sleep-in</string></array>
</dict></plist>
PLIST

# Sign from the inside out; the identifiers are what the daemon and client check.
sign=(codesign --force --options runtime --timestamp --sign "$identity")
"${sign[@]}" --identifier "$daemon_label" "$app_dir/Contents/MacOS/SleepInLidDaemon"
"${sign[@]}" --identifier io.github.qwertyu-alex.sleep-in.lid-client "$app_dir/Contents/MacOS/SleepInLidClient"
"${sign[@]}" --identifier io.github.qwertyu-alex.sleep-in.timer "$app_dir/Contents/MacOS/sleep-in"
"${sign[@]}" "$app_dir"
codesign --verify --deep --strict "$app_dir"
if [[ -n $output ]]; then
  print -r -- "Built $app_dir"
  exit 0
fi

[[ -e $installed ]] && mv "$installed" "$staging/previous.app"
mv "$app_dir" "$installed" || { mv "$staging/previous.app" "$installed"; exit 1; }
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed"
print -r -- "Built $installed"
