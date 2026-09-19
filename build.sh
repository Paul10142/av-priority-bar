#!/bin/bash
# Builds AV Priority Bar without Xcode - Command Line Tools are enough.
#
# Xcode's build system is only needed for the asset catalog, which this script
# replaces by generating an .icns from icon.png. Everything else is swiftc plus
# a hand-assembled .app bundle.
set -euo pipefail

APP_NAME="AVPriorityBar"
# Not "com.paulclancy.AVPriorityBar": macOS's menu bar refuses that identifier on
# the development machine. Control Center accepts the status item, then logs
# "Moving host to blocked list" and drops it, so the app runs with no icon. The
# block is keyed to the bundle identifier alone -- the same binary under any
# other identifier is placed normally -- and survives a reboot, a Control Center
# restart and a full reset of its preferences. Settings carry over in
# SettingsMigration.swift. Camera and microphone permission do not: macOS ties
# those to the identifier, so both are asked for again on first use.
BUNDLE_ID="com.paulclancy.AVPriority"
DEPLOY_TARGET="14.0"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/$APP_NAME"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
WORK="$ROOT/.build"

ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos${DEPLOY_TARGET}"

echo "Building $APP_NAME for $TARGET..."

rm -rf "$APP" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK"

# Keep the freshly built app out of Spotlight. Indexing it registers a second
# bundle with the same identifier as the copy in /Applications, so "open -a
# AVPriorityBar" and the login item can each pick a different one, and two
# instances end up running at once, fighting over the same menu bar slot.
touch "$DIST/.metadata_never_index"

# Work around a Command Line Tools bug where SwiftBridging is declared in both
# module.modulemap and bridging.modulemap, which makes every compile fail.
# A VFS overlay blanks the duplicate without touching the system directory.
CLT_SWIFT_INCLUDE="$(xcrun --find swiftc 2>/dev/null | xargs dirname | xargs dirname)/include/swift"
OVERLAY_ARGS=()
if [ -f "$CLT_SWIFT_INCLUDE/module.modulemap" ] && [ -f "$CLT_SWIFT_INCLUDE/bridging.modulemap" ] &&
   grep -q "module SwiftBridging" "$CLT_SWIFT_INCLUDE/module.modulemap" 2>/dev/null &&
   grep -q "module SwiftBridging" "$CLT_SWIFT_INCLUDE/bridging.modulemap" 2>/dev/null; then
  : > "$WORK/empty.modulemap"
  cat > "$WORK/overlay.yaml" <<EOF
{
  "version": 0,
  "case-sensitive": false,
  "roots": [
    {
      "type": "file",
      "name": "$CLT_SWIFT_INCLUDE/module.modulemap",
      "external-contents": "$WORK/empty.modulemap"
    }
  ]
}
EOF
  OVERLAY_ARGS=(-Xcc -ivfsoverlay -Xcc "$WORK/overlay.yaml")
  echo "  (applying Command Line Tools modulemap workaround)"
fi

SOURCES=$(find "$SRC" -name '*.swift' | sort)

swiftc -O -target "$TARGET" -parse-as-library \
  "${OVERLAY_ARGS[@]+"${OVERLAY_ARGS[@]}"}" \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework CoreAudio -framework ServiceManagement \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  $SOURCES

# App icon: build an .icns from the source PNG, no actool required.
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ROOT/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ROOT/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Unsigned bundles get a fresh identity on every rebuild, which
# makes macOS re-ask for camera access and forget the answer.
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP" 2>/dev/null

echo ""
echo "Build complete: dist/$APP_NAME.app"
echo "Install with:   ./install.sh"
