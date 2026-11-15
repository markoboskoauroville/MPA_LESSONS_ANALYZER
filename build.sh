#!/bin/sh
# build.sh: MPA Lessons Analyzer (Mantra).app. Run by GitHub Actions only (SIGN=- NO_INSTALL=1); never on the Mac.
set -e
cd "$(dirname "$0")"
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="MPA Lessons Analyzer (Mantra)"
APP="build/$NAME.app"
mkdir -p build; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -framework AVKit -framework AVFoundation -framework AppKit -framework Network -framework CoreImage -framework CoreMedia -framework CoreVideo -framework VideoToolbox -o "$APP/Contents/MacOS/MPALessonsAnalyzer" app/*.swift
swiftc -O -swift-version 5 -framework AVFoundation -framework AudioToolbox -framework Accelerate -o build/drumsplit drumsplit/main.swift
codesign --force -s "${SIGN:-Mantra Apps}" -i community.auroville.drumsplit build/drumsplit
cp build/drumsplit "$APP/Contents/MacOS/drumsplit"
cp icon/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>community.auroville.mpalessonsanalyzer</string>
<key>CFBundleExecutable</key><string>MPALessonsAnalyzer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$V</string>
<key>CFBundleVersion</key><string>$V</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>SHOOT listens when you press TALK, and the take records the sound with the picture.</string>
<key>NSCameraUsageDescription</key><string>Second Take shows the Sony camera full screen and records your lesson take.</string>
<key>NSBonjourServices</key><array><string>_secondtake._tcp</string></array>
<key>NSLocalNetworkUsageDescription</key><string>The Second Take Remote on your phone connects over the local network, after you type the code shown on the screen.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PL
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
if [ -z "$NO_INSTALL" ]; then rm -rf "/Applications/$NAME.app"; cp -R "$APP" /Applications/; fi
echo "built $APP (v$V)"
