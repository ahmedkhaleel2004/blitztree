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

APP=build/BlitzTree.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Swift UI"
# -default-isolation needs Swift 6.1 (Xcode 16.3+). Probe it: older Xcode
# falls back to Swift 5 mode, where isolation checking is lenient enough.
if ! echo 'func bzProbe() {}' | swiftc -swift-version 6 -default-isolation MainActor -typecheck - >/dev/null 2>&1; then
    echo "error: the installed Swift predates 6.1 and cannot build the UI;" >&2
    echo "       default-MainActor isolation needs Xcode 16.3 or newer." >&2
    exit 1
fi
swiftc app/*.swift \
    -import-objc-header app/bz.h \
    -O -parse-as-library "${SWIFT_VER[@]}" "${ISOLATION[@]}" \
    -target arm64-apple-macos$MIN_MACOS \
    -L target/release -lblitztree \
    -framework AppKit -framework SwiftUI \
    -o "$APP/Contents/MacOS/BlitzTree"

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
    <key>CFBundleDevelopmentRegion</key><string>en</string>
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

# Classic .lproj Localizable.strings tables (swiftc, no Xcode build system).
for LPROJ in app/*.lproj; do
    cp -R "$LPROJ" "$APP/Contents/Resources/"
done

# Prefer a real identity: stable code requirement -> TCC/FDA grants survive
# rebuilds. Developer ID (paid program) with the hardened runtime and a secure
# timestamp is what notarization needs; Apple Development is the fallback.
IDS=$(security find-identity -v -p codesigning 2>/dev/null)
IDENTITY=$(awk -F'"' '/Developer ID Application/{print $2; exit}' <<<"$IDS")
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    IDENTITY=$(awk -F'"' '/Apple Development/{print $2; exit}' <<<"$IDS")
    codesign --force --sign "${IDENTITY:--}" "$APP"
fi
echo "==> Built $APP"
