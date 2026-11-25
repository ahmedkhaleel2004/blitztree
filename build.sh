#!/bin/zsh
# Build BlitzTree.app: Rust engine + Swift UI, assembled into a bundle.
set -euo pipefail
cd "$(dirname "$0")"
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
VERSION=$(awk -F'"' '/^version/{print $2; exit}' Cargo.toml)
# Last three macOS releases. Newer-only UI (Liquid Glass) is gated with
# #available, so the compiler enforces that nothing newer slips in unguarded.
MIN_MACOS=14.0
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS

echo "==> Rust engine"
cargo build --release

# Sparkle (auto-updates), pinned by checksum and cached outside git.
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE=.cache/sparkle-$SPARKLE_VERSION
if [[ ! -d "$SPARKLE/Sparkle.framework" ]]; then
    echo "==> Sparkle $SPARKLE_VERSION"
    mkdir -p "$SPARKLE"
    curl -fsSL -o "$SPARKLE.tar.xz" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $SPARKLE.tar.xz" | shasum -a 256 -c --quiet
    tar -xf "$SPARKLE.tar.xz" -C "$SPARKLE" Sparkle.framework bin
    rm "$SPARKLE.tar.xz"
fi

APP=build/BlitzTree.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

echo "==> Swift UI"
swiftc app/*.swift \
    -import-objc-header app/bz.h \
    -O -parse-as-library -swift-version 6 -default-isolation MainActor \
    -target arm64-apple-macos$MIN_MACOS \
    -L target/release -lblitztree \
    -framework AppKit -framework SwiftUI \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$APP/Contents/MacOS/BlitzTree"
# The XPC services only serve sandboxed apps; BlitzTree isn't sandboxed.
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BlitzTree</string>
    <key>CFBundleDisplayName</key><string>BlitzTree</string>
    <key>CFBundleIdentifier</key><string>dev.ahmed.blitztree</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>BlitzTree</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Ahmed Khaleel</string>
    <key>SUFeedURL</key><string>https://github.com/ahmedkhaleel2004/blitztree/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>WtmMufGnr61vIAeONfQ4650BqnlBZ1uuD1gmngkX+os=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
</dict>
</plist>
EOF
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
# Icon Composer source → Assets.car (Liquid Glass, macOS 26+) plus a flat
# AppIcon.icns that older systems use. Regenerate the source with
# `python3 assets/gen_icon.py`.
xcrun actool "$PWD/assets/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
    --platform macosx --target-device mac --minimum-deployment-target $MIN_MACOS \
    --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon-partial.plist" >/dev/null

# The GUI executable stays linked to the library built without `cli`.
# This second invocation compiles only the JSON engine. The Swift front
# passes that engine's stdout through and finds it beside itself.
echo "==> Agent CLI"
cargo build --locked --release --features cli --bin blitztree
# Not `blitztree`. The default APFS volume is case-insensitive, so that name
# is the GUI executable `BlitzTree` and the copy would replace the app.
cp -f target/release/blitztree "$APP/Contents/MacOS/blitztree-engine"
swiftc cli/Harness.swift cli/main.swift app/Subprocess.swift \
    -O -parse-as-library -swift-version 6 -default-isolation MainActor \
    -target arm64-apple-macos$MIN_MACOS \
    -o "$APP/Contents/MacOS/cli-anything-blitztree"
[[ "$(stat -f '%i' "$APP/Contents/MacOS/BlitzTree")" != "$(stat -f '%i' "$APP/Contents/MacOS/blitztree-engine")" ]] || {
    echo "error: blitztree-engine and BlitzTree are the same file" >&2
    exit 1
}

# Prefer a real identity: stable code requirement -> TCC/FDA grants survive
# rebuilds. Developer ID (paid program) with the hardened runtime and a secure
# timestamp is what notarization needs; Apple Development is the fallback.
# The Developer ID key lives in its own keychain so codesign never prompts;
# unlock it if this machine has one.
SIGN_KC="$HOME/Library/Keychains/blitztree-signing.keychain-db"
SIGN_PASS="$HOME/.config/blitztree-signing/keychain.pass"
if [[ -f "$SIGN_KC" && -f "$SIGN_PASS" ]]; then
    security unlock-keychain -p "$(<"$SIGN_PASS")" "$SIGN_KC"
fi
IDS=$(security find-identity -v -p codesigning 2>/dev/null)
IDENTITY=$(awk -F'"' '/Developer ID Application/{print $2; exit}' <<<"$IDS")
# Sparkle's helpers are signed inside out before the app (never --deep).
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "$IDENTITY" ]]; then
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
else
    IDENTITY=$(awk -F'"' '/Apple Development/{print $2; exit}' <<<"$IDS")
    SIGN=(codesign --force --sign "${IDENTITY:--}")
fi
"${SIGN[@]}" "$SPARKLE_IN_APP/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE_IN_APP/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE_IN_APP"
"${SIGN[@]}" "$APP/Contents/MacOS/blitztree-engine"
"${SIGN[@]}" "$APP/Contents/MacOS/cli-anything-blitztree"
"${SIGN[@]}" "$APP"
echo "==> Built $APP"
