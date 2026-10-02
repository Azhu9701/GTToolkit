#!/bin/bash
# 构建 GT 音量助手 → ./GTVolume.app
set -euo pipefail
cd "$(dirname "$0")"

APP="GTVolume.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
  Sources/AudioController.swift \
  Sources/DDCController.swift \
  Sources/VolumeManager.swift \
  Sources/MediaKeyTap.swift \
  Sources/MenuBarController.swift \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/GTVolume" \
  -framework AppKit -framework CoreAudio -framework ServiceManagement -framework IOKit \
  -F "$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks" -framework CoreDisplay

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "构建完成:$(pwd)/$APP"
