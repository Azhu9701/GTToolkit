#!/bin/bash
# 构建分发用 DMG(拖拽安装布局):GTToolkit-<版本>-arm64.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP="GTToolkit.app"
DMG="GTToolkit-${VERSION}-arm64.dmg"
STAGE="dmg-stage"

./build.sh

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "GT 工具箱" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "DMG 构建完成:$(pwd)/$DMG"
