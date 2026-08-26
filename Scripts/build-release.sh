#!/bin/bash
# Builds a Release copy of KiCad QuickLook.app signed with Developer ID.
#
# Usage:
#   Scripts/build-release.sh [TEAM_ID]
#
# TEAM_ID defaults to the DEVELOPMENT_TEAM in project.yml. Output lands in
# build/Release/KiCad QuickLook.app.

set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${1:-LK2RWK9EUK}"

if ! command -v xcodegen >/dev/null; then
    echo "xcodegen not found; install with: brew install xcodegen" >&2
    exit 1
fi

xcodegen generate

xcodebuild \
    -project KiCadQuickLook.xcodeproj \
    -scheme KiCadQuickLook \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build

mkdir -p build/Release
rm -rf "build/Release/KiCad QuickLook.app"
cp -R "build/DerivedData/Build/Products/Release/KiCad QuickLook.app" build/Release/

echo
echo "Built: build/Release/KiCad QuickLook.app"
codesign -dv "build/Release/KiCad QuickLook.app" 2>&1 | grep -E "Authority|TeamIdentifier" | head -4
