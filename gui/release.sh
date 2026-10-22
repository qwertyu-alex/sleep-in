#!/bin/zsh
# Build, notarize, and publish a GitHub release: ./gui/release.sh 1.0.0 [notes.md]
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

rm -rf "$dist"
mkdir -p "$dist"
SLEEP_IN_OUTPUT="$dist" SLEEP_IN_VERSION="$version" "$source_dir/build.sh"

# Apple notarizes the zip; the ticket is then stapled to the app so it opens offline.
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
rm "$archive"
ditto -c -k --keepParent "$app" "$archive"
spctl --assess --type execute --verbose "$app"

if [[ -n $notes ]]; then
  gh release create "v$version" "$archive" --target "$commit" --title "Sleep In $version" --notes-file "$notes"
else
  gh release create "v$version" "$archive" --target "$commit" --title "Sleep In $version" --generate-notes
fi
