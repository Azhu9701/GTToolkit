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
  Sources/SMCLite.swift \
  Sources/FanController.swift \
  Sources/ModelMonitor.swift \
  Sources/MediaKeyTap.swift \
  Sources/MenuBarController.swift \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/GTVolume" \
  -framework AppKit -framework CoreAudio -framework ServiceManagement -framework IOKit -framework Security \
  -F "$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks" -framework CoreDisplay

# 特权风扇控制助手(内嵌进 bundle,运行时经管理员授权以 root 拉起;
# 也可安装为常驻 LaunchDaemon,负责唤醒后音频假死自动修复)
swiftc -O -swift-version 5 \
  Sources/SMCLite.swift \
  Sources/FanHelperMain.swift \
  -o "$APP/Contents/MacOS/gt-fanctl" \
  -framework IOKit -framework CoreAudio -framework CoreGraphics -framework AudioToolbox

cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "构建完成:$(pwd)/$APP"
