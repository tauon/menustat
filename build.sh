#!/bin/bash
# Build a native, locally signed .app using only Apple's Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

deployment_target=15.0
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p build
build_stage=$(mktemp -d "$PWD/build/.menustat.XXXXXX")
trap 'rm -rf "$build_stage"' EXIT
app_bundle="$build_stage/menustat.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"

for source in CPUInfo NetInfo NetProcStats; do
    xcrun --sdk macosx clang -O2 -fobjc-arc -fmodules -Wall -Wextra -Werror \
        -isysroot "$sdk_path" -mmacosx-version-min="$deployment_target" \
        -c "$source.m" -o "$build_stage/$source.o"
done
xcrun --sdk macosx swiftc -O -whole-module-optimization -warnings-as-errors \
    -sdk "$sdk_path" -target "$(uname -m)-apple-macosx$deployment_target" \
    -module-name menustat -import-objc-header menustat-Bridging-Header.h \
    menustat/ProcMonitor.swift menustat/AppDelegate.swift \
    "$build_stage/CPUInfo.o" "$build_stage/NetInfo.o" "$build_stage/NetProcStats.o" \
    -o "$app_bundle/Contents/MacOS/menustat"

# The catalog only contains the app icon. iconutil handles it without actool.
icon_source=menustat/Assets.xcassets/AppIcon.appiconset
icon_set="$build_stage/AppIcon.iconset"
mkdir -p "$icon_set"
cp "$icon_source"/icon_*.png "$icon_set/"
sips -z 16 16 "$icon_source/icon_16x16@2x.png" --out "$icon_set/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_source/icon_16x16@2x.png" --out "$icon_set/icon_32x32.png" >/dev/null
iconutil -c icns "$icon_set" -o "$app_bundle/Contents/Resources/AppIcon.icns"

plist="$app_bundle/Contents/Info.plist"
cp menustat/Info.plist "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable menustat' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.digitalsophistry.menustat' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName menustat' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon.icns' "$plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $deployment_target" "$plist"
plutil -lint "$plist"
codesign --force --sign - "$app_bundle"
codesign --verify --strict "$app_bundle"

# Replace only after compilation, packaging, and signing have succeeded.
if [[ -e build/menustat.app ]]; then
    mv build/menustat.app "$build_stage/previous.app"
fi
mv "$app_bundle" build/menustat.app
echo "Built $PWD/build/menustat.app"
echo 'Run with: open build/menustat.app'
