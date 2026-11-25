#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build/app-build"
MODULE_CACHE="/tmp/fanline-module-cache"
APP_BUNDLE="$ROOT_DIR/Fanline.app"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

if [[ -x "/Library/Developer/CommandLineTools/usr/bin/swiftc" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" ]]; then
  SWIFTC="/Library/Developer/CommandLineTools/usr/bin/swiftc"
  CLANG="/Library/Developer/CommandLineTools/usr/bin/clang"
  SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
else
  SWIFTC="$(xcrun --find swiftc)"
  CLANG="$(xcrun --find clang)"
  SDK_PATH="$(xcrun --show-sdk-path)"
fi

echo "[1/4] Compiling C bridge (CSMCKit)..."
"$CLANG" -c -O2 -fPIC \
  -arch arm64 \
  -mmacosx-version-min=14.0 \
  -isysroot "$SDK_PATH" \
  -I"$ROOT_DIR/Sources/CSMCKit/include" \
  "$ROOT_DIR/Sources/CSMCKit/CSMCKit.c" \
  -o "$BUILD_DIR/CSMCKit.o"

ar rcs "$BUILD_DIR/libCSMCKit.a" "$BUILD_DIR/CSMCKit.o"

echo "[2/4] Compiling privileged helper (mm-smc-helper)..."
"$SWIFTC" -O \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$ROOT_DIR/Sources/CSMCKit/include" \
  -L "$BUILD_DIR" -lCSMCKit \
  -framework IOKit -framework CoreFoundation \
  "$ROOT_DIR/Sources/SMCKit/SMCClient.swift" \
  "$ROOT_DIR/Sources/mm-smc-helper/main.swift" \
  -o "$APP_BUNDLE/Contents/MacOS/mm-smc-helper"

echo "[3/4] Compiling native macOS app (Fanline)..."
"$SWIFTC" -O \
  -target arm64-apple-macosx14.0 \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -I "$ROOT_DIR/Sources/CSMCKit/include" \
  -L "$BUILD_DIR" -lCSMCKit \
  -framework AppKit -framework SwiftUI -framework IOKit -framework CoreFoundation -framework ServiceManagement \
  "$ROOT_DIR/Sources/SMCKit/SMCClient.swift" \
  "$ROOT_DIR"/Sources/Fanline/**/*.swift(.N) \
  -o "$APP_BUNDLE/Contents/MacOS/Fanline"

echo "[4/4] Writing Info.plist & resources for Fanline.app..."
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"
if [[ ! -f "$ICON_FILE" ]]; then
  "${SWIFTC%c}" -sdk "$SDK_PATH" -module-cache-path "$MODULE_CACHE" "$ROOT_DIR/scripts/generate_icon.swift" "$ICON_FILE"
fi
cp -f "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Fanline</string>
    <key>CFBundleExecutable</key>
    <string>Fanline</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.fiveamai.Fanline</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Fanline</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

chmod +x "$APP_BUNDLE/Contents/MacOS/Fanline" "$APP_BUNDLE/Contents/MacOS/mm-smc-helper"
touch "$APP_BUNDLE"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
fi
echo "✅ Successfully built: $APP_BUNDLE"
