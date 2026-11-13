#!/bin/sh
# build.sh: MPA Lessons Analyzer (Mantra).app. Run by GitHub Actions only (SIGN=- NO_INSTALL=1); never on the Mac.
set -e
cd "$(dirname "$0")"
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
NAME="MPA Lessons Analyzer (Mantra)"
APP="build/$NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -framework AVKit -framework AVFoundation -framework AppKit -framework Network -o "$APP/Contents/MacOS/MPALessonsAnalyzer" app/*.swift
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
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PL
codesign --force -s "${SIGN:-Mantra Apps}" "$APP"
if [ -z "$NO_INSTALL" ]; then rm -rf "/Applications/$NAME.app"; cp -R "$APP" /Applications/; fi
echo "built $APP (v$V)"
