#!/bin/bash
# Notarizes and staples the Release build for direct distribution.
#
# Prerequisites (one-time):
#   xcrun notarytool store-credentials kicadquicklook \
#       --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#   (generates an app-specific password at appleid.apple.com when prompted)
#
# Usage:
#   Scripts/notarize.sh [KEYCHAIN_PROFILE]
#
# Produces build/Release/KiCadQuickLook.zip ready for distribution.

set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-kicadquicklook}"
APP="build/Release/KiCad QuickLook.app"
ZIP="build/Release/KiCadQuickLook.zip"

if [ ! -d "$APP" ]; then
    echo "No release build found; run Scripts/build-release.sh first" >&2
    exit 1
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting for notarization (waits until Apple responds)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling ticket…"
xcrun stapler staple "$APP"

# Re-zip with the stapled ticket included.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done: $ZIP"
spctl -a -vv "$APP" 2>&1 | head -3
