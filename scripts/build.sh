#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --product CapsFlow
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/CapsFlow.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/dist/AppIcon.iconset"
cp "$bin_dir/CapsFlow" "$app/Contents/MacOS/CapsFlow"
cp Resources/Info.plist "$app/Contents/Info.plist"
ditto "$bin_dir/CapsFlow_InputCore.bundle" "$app/Contents/Resources/CapsFlow_InputCore.bundle"
xcrun swift scripts/make-icon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - --identifier local.capsflow.app "$app"
codesign --verify --deep --strict "$app"
print "Built: $app"
