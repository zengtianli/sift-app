#!/bin/bash
# Standalone local build. Public distribution requires Developer ID + notarization.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
TARGET_DIR="${CARGO_TARGET_DIR:-$DIR/core/target}"
# Keep proc-macro dylibs intact; Apple strip can misalign their LINKEDIT pool.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none
test -d third_party/cardinal/search-cache
(cd core && MACOSX_DEPLOYMENT_TARGET=14.0 "$CARGO" build --release --locked -j "${CARGO_BUILD_JOBS:-12}")
mkdir -p build
STAGE="$(mktemp -d "$DIR/build/compile.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Sift.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(find Sources -type f -name '*.swift' | LC_ALL=C sort)
xcrun swiftc -swift-version 5 -O -whole-module-optimization -target arm64-apple-macos14.0 \
  -D APP_LIFECYCLE_LOCAL_ONLY -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -I core/include -L "$TARGET_DIR/release" -Xlinker -dead_strip \
  -framework CoreServices -framework Carbon -framework Quartz \
  "${SOURCES[@]}" -o "$APP/Contents/MacOS/Sift"
cp "$TARGET_DIR/release/sift" "$APP/Contents/Resources/bin/sift"
strip -x "$APP/Contents/MacOS/Sift"
IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$IDENTITY" = '-' ]; then
  codesign --force --sign - --identifier cyou.tianli.sift.cli "$APP/Contents/Resources/bin/sift"
  codesign --force --sign - --identifier cyou.tianli.sift "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --identifier cyou.tianli.sift.cli "$APP/Contents/Resources/bin/sift"
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict "$APP"
test "$(lipo -archs "$APP/Contents/MacOS/Sift")" = arm64
"$APP/Contents/Resources/bin/sift" --version
test ! -e build/Sift.app || mv build/Sift.app "build/Sift.previous.$(date +%s).app"
mv "$APP" build/Sift.app
echo "Built: $DIR/build/Sift.app"
