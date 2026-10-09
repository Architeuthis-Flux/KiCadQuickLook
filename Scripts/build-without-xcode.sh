#!/bin/bash
# Builds, signs, and optionally installs KiCad QuickLook.app using only the
# Command Line Tools (no Xcode): compiles each target with swiftc, assembles
# the .app and .appex bundles by hand, and signs them inner-to-outer.
#
# Usage:
#   Scripts/build-without-xcode.sh [--install]
#
# Environment:
#   IDENTITY   codesign identity (default: "Developer ID Application";
#              use "-" for an ad-hoc signature)
#   ARCHS      architectures to build, space separated (default: arm64;
#              "arm64 x86_64" produces a universal binary)
#   OUT        build directory (default: build/cli)
#   SDK        macOS SDK path. Defaults to the Command Line Tools' macOS 26
#              SDK when present: from the macOS 27 SDK on, SwiftUI's @State
#              is a macro whose plugin only ships with Xcode, so the app
#              target cannot be compiled against it with the CLT alone.
#
# --install copies the app to /Applications, registers it with
# LaunchServices, enables both Quick Look extensions, and resets the Quick
# Look cache. Launch the app once afterwards if Finder still ignores the
# new file types.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-Developer ID Application}"
ARCHS="${ARCHS:-arm64}"
OUT="${OUT:-build/cli}"
DEPLOYMENT_TARGET=13.0
if [ -z "${SDK:-}" ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
    [ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
fi
echo "SDK: $SDK"
INSTALL=0
[ "${1:-}" = "--install" ] && INSTALL=1

APP="$OUT/KiCad QuickLook.app"
PLUGINS="$APP/Contents/PlugIns"
RESOURCES=(
    Vendor/kicanvas/kicanvas.js
    Vendor/online-3d-viewer/o3dv.min.js
    Vendor/occt-import-js/occt-import-js.js
    Vendor/occt-import-js/occt-import-js.wasm
)

rm -rf "$APP"
mkdir -p "$OUT"

# compile <module> <output> <plist-template> <extension:0|1> <sources...> -- <frameworks...>
compile() {
    local module=$1 output=$2 extension=$3
    shift 3
    local sources=() frameworks=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do sources+=("$1"); shift; done
    shift
    while [ $# -gt 0 ]; do frameworks+=(-framework "$1"); shift; done

    local flags=(-O -parse-as-library -module-name "$module" -sdk "$SDK")
    if [ "$extension" = 1 ]; then
        flags+=(-application-extension -Xlinker -e -Xlinker _NSExtensionMain)
    fi

    local slices=()
    for arch in $ARCHS; do
        echo "  swiftc $module ($arch)"
        swiftc "${flags[@]}" -target "$arch-apple-macos$DEPLOYMENT_TARGET" \
            "${sources[@]}" "${frameworks[@]}" -o "$output.$arch"
        slices+=("$output.$arch")
    done
    if [ ${#slices[@]} -eq 1 ]; then
        mv "${slices[0]}" "$output"
    else
        lipo -create "${slices[@]}" -output "$output"
        rm -f "${slices[@]}"
    fi
}

# plist <template> <destination> <executable> <bundle-id> <product-name>
plist() {
    local template=$1 destination=$2 executable=$3 bundle_id=$4 product=$5
    sed -e 's/\$(DEVELOPMENT_LANGUAGE)/en/g' \
        -e "s/\$(EXECUTABLE_NAME)/$executable/g" \
        -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundle_id/g" \
        -e "s/\$(PRODUCT_NAME)/$product/g" \
        "$template" > "$destination"
    /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $DEPLOYMENT_TARGET" "$destination" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" \
        -c "Add :CFBundleSupportedPlatforms:0 string MacOSX" "$destination" >/dev/null
    plutil -lint "$destination" >/dev/null
}

copy_resources() {
    local destination=$1
    mkdir -p "$destination"
    for resource in "${RESOURCES[@]}"; do cp "$resource" "$destination/"; done
}

echo "Building extensions..."
for spec in "PreviewExtension:KiCadPreviewExtension:PreviewExtension/PreviewViewController.swift:Quartz" \
            "ThumbnailExtension:KiCadThumbnailExtension:ThumbnailExtension/ThumbnailProvider.swift:QuickLookThumbnailing"; do
    IFS=: read -r directory product source framework <<< "$spec"
    appex="$PLUGINS/$product.appex"
    mkdir -p "$appex/Contents/MacOS"
    compile "$product" "$appex/Contents/MacOS/$product" 1 \
        "$source" Shared/*.swift -- "$framework" WebKit AppKit
    plist "$directory/Info.plist" "$appex/Contents/Info.plist" "$product" \
        "com.kevincappuccio.KiCadQuickLook.$directory" "$product"
    printf 'XPC!????' > "$appex/Contents/PkgInfo"
    copy_resources "$appex/Contents/Resources"
done

echo "Building app..."
mkdir -p "$APP/Contents/MacOS"
compile "KiCadQuickLook" "$APP/Contents/MacOS/KiCad QuickLook" 0 \
    App/*.swift Shared/*.swift -- SwiftUI WebKit AppKit
plist App/Info.plist "$APP/Contents/Info.plist" "KiCad QuickLook" \
    "com.kevincappuccio.KiCadQuickLook" "KiCad QuickLook"
printf 'APPL????' > "$APP/Contents/PkgInfo"
copy_resources "$APP/Contents/Resources"
cp -R SampleFiles "$APP/Contents/Resources/SampleFiles"

echo "Signing with: $IDENTITY"
sign() {
    codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
        --entitlements "$1" "$2"
}
sign PreviewExtension/PreviewExtension.entitlements "$PLUGINS/KiCadPreviewExtension.appex"
sign ThumbnailExtension/ThumbnailExtension.entitlements "$PLUGINS/KiCadThumbnailExtension.appex"
sign App/KiCadQuickLook.entitlements "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

echo
echo "Built: $APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier)" | head -3

if [ "$INSTALL" = 1 ]; then
    DEST="/Applications/KiCad QuickLook.app"
    echo
    echo "Installing to ${DEST}..."
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREGISTER" -f "$DEST"
    for product in KiCadPreviewExtension KiCadThumbnailExtension; do
        pluginkit -a "$DEST/Contents/PlugIns/$product.appex"
    done
    pluginkit -e use -i com.kevincappuccio.KiCadQuickLook.PreviewExtension
    pluginkit -e use -i com.kevincappuccio.KiCadQuickLook.ThumbnailExtension
    qlmanage -r >/dev/null 2>&1 || true
    qlmanage -r cache >/dev/null 2>&1 || true
    echo "Registered Quick Look extensions:"
    pluginkit -m -v -i com.kevincappuccio.KiCadQuickLook.PreviewExtension
    pluginkit -m -v -i com.kevincappuccio.KiCadQuickLook.ThumbnailExtension
fi
