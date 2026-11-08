#!/bin/sh
# Builds "SkyTrak Stats.app" for Intel and Apple Silicon, and zips it into dist/.
#   VERSION=1.2.3 scripts/build.sh    release build
#   DEV=1 scripts/build.sh            adds test hooks and skips self-install
set -eu
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.1}"
APP="build/SkyTrak Stats.app"
SDK="$(xcrun --show-sdk-path)"
FLAGS=""
[ -n "${DEV:-}" ] && FLAGS="-D DEV"

rm -rf build dist
mkdir -p build dist "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 $FLAGS -target "$ARCH-apple-macos12.0" -sdk "$SDK" \
    -framework Cocoa -framework WebKit Sources/*.swift -o "build/SkyTrakStats-$ARCH"
done
lipo -create build/SkyTrakStats-arm64 build/SkyTrakStats-x86_64 -output "$APP/Contents/MacOS/SkyTrakStats"

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/index.html "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" dist/SkyTrakStats.zip
echo "Built $APP (v$VERSION)"
