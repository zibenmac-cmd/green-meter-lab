#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
probe_cache="${TMPDIR:-/private/tmp}/socket-ip-probe-swift-cache"
for arch in arm64 x86_64; do
  /usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$probe_cache" -O -target "$arch-apple-macosx13.0" Source/ProbeCore.swift Source/ProbeRunner.swift Source/ProbeApp.swift Source/main.swift -o "build/SocketIPProbe-$arch"
done
probe_app="插座IP读取测试器.app"
mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources"
/usr/bin/lipo -create build/SocketIPProbe-arm64 build/SocketIPProbe-x86_64 -output "$probe_app/Contents/MacOS/SocketIPProbe"
cp Source/Info.plist "$probe_app/Contents/Info.plist"
if [[ -f Source/AppIcon.icns ]]; then cp Source/AppIcon.icns "$probe_app/Contents/Resources/AppIcon.icns"; fi
for metadata in com.apple.FinderInfo com.apple.ResourceFork; do /usr/bin/xattr -dr "$metadata" "$probe_app" 2>/dev/null || true; done
/usr/bin/codesign --force --deep --sign - "$probe_app"
/usr/bin/codesign --verify --deep --strict "$probe_app"
print "Built: ${PWD}/${probe_app}"
