#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/../.."
mkdir -p build
cache_dir="${TMPDIR:-/private/tmp}/green-meter-swift-cache"
test_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/green-meter-cloud-160.XXXXXX")
/usr/bin/xcrun swiftc -swift-version 5 -module-cache-path "$cache_dir" Source/Protocol.swift Source/DeviceCommands.swift Source/Power.swift Source/Learning.swift Source/LearningController.swift Source/Storage.swift Source/CloudSync.swift Source/CloudController.swift Source/App.swift Tests/CloudIntegration/main.swift -o build/CloudSyncTests
python3 Tests/CloudIntegration/server.py "$test_dir" ./build/CloudSyncTests
print "测试记录：$test_dir"
