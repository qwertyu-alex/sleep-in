#!/bin/zsh
# Build, notarize, and publish a GitHub release: ./gui/release.sh 1.0.0 [notes.md]
# Installed copies find it through the release's appcast.xml and update themselves.
set -eu

version="${1:?Usage: ./gui/release.sh VERSION [NOTES_FILE]}"
notes="${2:-}"
# Create once with: xcrun notarytool store-credentials sleep-in-notary --apple-id EMAIL --team-id TEAM
profile="${SLEEP_IN_NOTARY_PROFILE:-sleep-in-notary}"
source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
dist="$source_dir/../dist"
app="$dist/Sleep In.app"
archive="$dist/Sleep-In.zip"

if [[ -n "$(git -C "$source_dir" status --porcelain)" ]]; then
  print -u2 "Commit or stash your changes first; the release is built from the current checkout."
  exit 1
fi
commit="$(git -C "$source_dir" rev-parse HEAD)"
git -C "$source_dir" fetch --quiet origin
if [[ -z "$(git -C "$source_dir" branch -r --contains "$commit")" ]]; then
  print -u2 "Push this commit first; the release tag points at it."
  exit 1
fi

sparkle="$("$source_dir/fetch-sparkle.sh")"
# The private half stays in the login keychain; create it once with "$(./gui/fetch-sparkle.sh)/bin/generate_keys".
if ! update_key="$("$sparkle/bin/generate_keys" -p 2>/dev/null)"; then
  print -u2 "No update signing key found. Create one with: $sparkle/bin/generate_keys"
  exit 1
fi
repository="$(cd "$source_dir" && gh repo view --json url --jq .url)"

rm -rf "$dist"
mkdir -p "$dist"
SLEEP_IN_OUTPUT="$dist" SLEEP_IN_VERSION="$version" \
  SLEEP_IN_FEED_URL="$repository/releases/latest/download/appcast.xml" SLEEP_IN_UPDATE_KEY="$update_key" \
  "$source_dir/build.sh"

# Apple notarizes the zip; the ticket is then stapled to the app so it opens offline.
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
rm "$archive"
ditto -c -k --keepParent "$app" "$archive"
spctl --assess --type execute --verbose "$app"

"$source_dir/appcast.sh" "$version" "$archive" "$repository/releases/download/v$version/Sleep-In.zip" \
  "$repository/releases/tag/v$version" "$notes" > "$dist/appcast.xml"
xmllint --noout "$dist/appcast.xml"

if [[ -n $notes ]]; then
  gh release create "v$version" "$archive" "$dist/appcast.xml" --target "$commit" --title "Sleep In $version" --notes-file "$notes"
else
  gh release create "v$version" "$archive" "$dist/appcast.xml" --target "$commit" --title "Sleep In $version" --generate-notes
fi
