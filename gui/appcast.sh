#!/bin/zsh
# Prints a Sparkle appcast that offers one update:
# ./gui/appcast.sh VERSION ZIP DOWNLOAD_URL RELEASE_PAGE_URL [NOTES.md]
set -eu

version="$1"
archive="$2"
download="$3"
page="$4"
notes="${5:-}"
sparkle="$("$(dirname -- "$0")/fetch-sparkle.sh")"

# Sparkle only installs a download whose EdDSA signature matches the app's SUPublicEDKey.
signature="$("$sparkle/bin/sign_update" "$archive")"
description=""
if [[ -n $notes ]]; then
  html="$(gh api markdown -f mode=gfm -F text=@"$notes")"
  description="<description><![CDATA[${html//]]>/]]]]><![CDATA[>}]]></description>"
fi

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sleep In</title>
    <item>
      <title>Sleep In $version</title>
      <link>$page</link>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
      $description
      <enclosure url="$download" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
