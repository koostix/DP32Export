#!/bin/sh
# Builds "build/DP32 Export.app" and build/dp32export, ad-hoc signs both, and zips them.
#   sh scripts/package.sh              native architecture
#   sh scripts/package.sh --universal  Apple Silicon + Intel (needs Xcode)
set -eu
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo dev)}"
VERSION="${VERSION#v}"
ARCH=""
[ "${1:-}" = "--universal" ] && ARCH="--arch arm64 --arch x86_64"

# shellcheck disable=SC2086
swift build -c release $ARCH --product DP32ExportApp
# shellcheck disable=SC2086
swift build -c release $ARCH --product dp32export
# shellcheck disable=SC2086
BIN="$(swift build -c release $ARCH --show-bin-path)"

APP="build/DP32 Export.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DP32ExportApp" "$APP/Contents/MacOS/DP32ExportApp"
cp "$BIN/dp32export" build/dp32export

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DP32ExportApp</string>
    <key>CFBundleIdentifier</key><string>io.github.koostix.dp32export</string>
    <key>CFBundleName</key><string>DP32 Export</string>
    <key>CFBundleDisplayName</key><string>DP-32 Export</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signatures: enough for Apple Silicon to run them. Not notarized.
codesign --force --deep --sign - "$APP"
codesign --force --sign - build/dp32export

ZIP="build/DP32Export-$VERSION-macOS.zip"
STAGE="build/DP32Export-$VERSION"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp build/dp32export README.md LICENSE "$STAGE/"
ditto -c -k --keepParent "$STAGE" "$ZIP"
rm -rf "$STAGE"
echo "App: $PWD/$APP"
echo "CLI: $PWD/build/dp32export"
echo "Zip: $PWD/$ZIP"
