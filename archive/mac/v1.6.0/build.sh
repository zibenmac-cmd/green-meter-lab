#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
cache_dir="${TMPDIR:-/private/tmp}/green-meter-swift-cache"
for arch in arm64 x86_64; do
  /usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$cache_dir" -O -target "$arch-apple-macosx13.0" Source/Protocol.swift Source/DeviceCommands.swift Source/Power.swift Source/Learning.swift Source/LearningController.swift Source/Storage.swift Source/CloudSync.swift Source/CloudController.swift Source/App.swift Source/main.swift -o "build/GreenMeterMac-$arch"
done
app_path="绿电实验室.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
/usr/bin/lipo -create build/GreenMeterMac-arm64 build/GreenMeterMac-x86_64 -output "$app_path/Contents/MacOS/GreenMeterMac"
cp Source/index.html "$app_path/Contents/Resources/index.html"
cp Evidence/F251D351-实测原始.bin "$app_path/Contents/Resources/"
cp Source/Info.plist "$app_path/Contents/Info.plist"
if [[ -f Source/AppIcon.icns ]]; then cp Source/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"; fi
for metadata in com.apple.FinderInfo com.apple.ResourceFork; do
  /usr/bin/xattr -dr "$metadata" "$app_path" 2>/dev/null || true
done
/usr/bin/codesign --force --deep --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
print "Built: ${PWD}/${app_path}"
