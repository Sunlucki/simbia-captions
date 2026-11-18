#!/bin/zsh
set -euo pipefail
swift build -c release
APP_DIR="../Simbia Captions.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp .build/release/SimbiaCaptions "$APP_DIR/Contents/MacOS/SimbiaCaptions"
# the engine inside the app too: a new workspace's .mcp.json points Claude at it
cp .build/release/simbia "$APP_DIR/Contents/MacOS/simbia"
cp Assets/AppIcon.png "$APP_DIR/Contents/Resources/AppIcon.png"
cp Assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
# the .simbia files' own icon in Finder (Assets/DocIcon.iconset -> iconutil)
cp Assets/SimbiaDocument.icns "$APP_DIR/Contents/Resources/SimbiaDocument.icns"
cp Assets/LogoWhite.mov "$APP_DIR/Contents/Resources/LogoWhite.mov"
cp Assets/LogoWhiteLoop.mov "$APP_DIR/Contents/Resources/LogoWhiteLoop.mov"
cp -R Assets/Fonts "$APP_DIR/Contents/Resources/Fonts"
if [ -d Assets/Brand ]; then cp -R Assets/Brand "$APP_DIR/Contents/Resources/Brand"; fi
# The engine without the window, for Claude and scripts: Portable/bin/simbia
mkdir -p ../bin
cp .build/release/simbia ../bin/simbia
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SimbiaCaptions</string>
<key>CFBundleIdentifier</key><string>local.simbia.captions</string>
<key>CFBundleName</key><string>Simbia Captions</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string><string>fr</string></array>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>CFBundleDocumentTypes</key><array><dict>
  <key>CFBundleTypeName</key><string>Simbia Project</string>
  <key>CFBundleTypeRole</key><string>Editor</string>
  <key>CFBundleTypeIconFile</key><string>SimbiaDocument</string>
  <key>LSHandlerRank</key><string>Owner</string>
  <key>LSItemContentTypes</key><array><string>local.simbia.project</string></array>
</dict></array>
<key>UTExportedTypeDeclarations</key><array><dict>
  <key>UTTypeIdentifier</key><string>local.simbia.project</string>
  <key>UTTypeDescription</key><string>Simbia Project</string>
  <key>UTTypeIconFile</key><string>SimbiaDocument</string>
  <key>UTTypeConformsTo</key><array><string>public.json</string></array>
  <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>simbia</string></array></dict>
</dict></array>
</dict></plist>
PLIST
# Register the document type with Launch Services so Finder and `open` route .simbia here.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" || true
echo "Created $APP_DIR"
