#!/bin/sh
set -e

# Config
APP_NAME="Dory Port Forwarder"
BUNDLE_NAME="DoryPortForwarder.app"
BINARY_NAME="DoryPortForwarder"

echo "=== Building $APP_NAME ==="

# 1. Compile Swift code
echo "Compiling Swift source..."
swiftc -O -sdk $(xcrun --show-sdk-path) -parse-as-library DoryPFGUI.swift -o "$BINARY_NAME"

echo "Compiling proxy engine..."
swiftc -O -sdk $(xcrun --show-sdk-path) proxy/dory-pf-proxy.swift -o dory-pf-proxy

# 2. Create App Bundle structure
echo "Creating app bundle structure..."
mkdir -p "$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUNDLE_NAME/Contents/Resources"

# 3. Move binaries and resources
mv "$BINARY_NAME" "$BUNDLE_NAME/Contents/MacOS/$BINARY_NAME"
mv dory-pf-proxy "$BUNDLE_NAME/Contents/MacOS/dory-pf-proxy"
if [ -f "AppIcon.icns" ]; then
  echo "Copying AppIcon.icns..."
  cp "AppIcon.icns" "$BUNDLE_NAME/Contents/Resources/AppIcon.icns"
fi

# 4. Create Info.plist
echo "Creating Info.plist..."
cat <<EOF > "$BUNDLE_NAME/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>$BINARY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>local.dory.portforwarder</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 5. Ad-hoc codesign both binaries. This reduces macOS firewall/Gatekeeper
# prompts on launch; it does not require any credentials or admin rights.
if command -v codesign >/dev/null 2>&1; then
  echo "Ad-hoc signing binaries..."
  codesign --force --sign - "$BUNDLE_NAME/Contents/MacOS/dory-pf-proxy" 2>/dev/null || true
  codesign --force --sign - "$BUNDLE_NAME/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true
fi

echo "=== Build Successful! ==="
echo "You can find your app at: $(pwd)/$BUNDLE_NAME"
