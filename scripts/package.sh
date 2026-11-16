#!/bin/sh
# Builds "build/DP32 Export.app" and build/dp32export, ad-hoc signs both, and makes
# a distributable DMG (and a zip) holding the app, the CLI, Read Me First.txt and the license.
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

rm -rf build
APP="build/DP32 Export.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/DP32ExportApp" "$APP/Contents/MacOS/DP32ExportApp"
cp "$BIN/dp32export" build/dp32export

# App icon from Resources/AppIcon.png (1024x1024).
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DP32ExportApp</string>
    <key>CFBundleIdentifier</key><string>io.github.koostix.dp32export</string>
    <key>CFBundleName</key><string>DP32 Export</string>
    <key>CFBundleDisplayName</key><string>DP-32 Export</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHumanReadableCopyright</key><string>MIT License. Provided as is, without warranty. Use at your own risk.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signatures: enough for Apple Silicon to run them. Not notarized.
codesign --force --deep --sign - "$APP"
codesign --force --sign - build/dp32export

# What the user sees when the DMG opens.
STAGE="build/DP32 Export $VERSION"
mkdir -p "$STAGE/Command Line Tool"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Read Me First.txt" "$STAGE/"
cp LICENSE "$STAGE/License.txt"
cp build/dp32export "$STAGE/Command Line Tool/"

DMG="build/DP32Export-$VERSION.dmg"
hdiutil create -volname "DP32 Export $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
ZIP="build/DP32Export-$VERSION-macOS.zip"
ditto -c -k --keepParent "$STAGE" "$ZIP"
rm -rf "$STAGE"

echo "App: $PWD/$APP"
echo "CLI: $PWD/build/dp32export"
echo "DMG: $PWD/$DMG"
echo "Zip: $PWD/$ZIP"
