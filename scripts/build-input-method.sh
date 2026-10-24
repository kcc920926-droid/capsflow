#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --product CapsFlowInputMethod
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/CapsFlowInputMethod.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/dist/InputMethodIcon.iconset"
mkdir -p "$app/Contents/Resources/ko.lproj" "$app/Contents/Resources/en.lproj"
cp "$bin_dir/CapsFlowInputMethod" "$app/Contents/MacOS/CapsFlowInputMethod"
cp Resources/InputMethod-Info.plist "$app/Contents/Info.plist"
cp Resources/InputMethod-InfoPlist.strings "$app/Contents/Resources/ko.lproj/InfoPlist.strings"
cp Resources/InputMethod-InfoPlist.strings "$app/Contents/Resources/en.lproj/InfoPlist.strings"
ditto "$bin_dir/CapsFlow_InputCore.bundle" "$app/Contents/Resources/CapsFlow_InputCore.bundle"
xcrun swift scripts/make-icon.swift "$PWD/dist/InputMethodIcon.iconset"
iconutil -c icns "$PWD/dist/InputMethodIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - --identifier local.inputmethod.capsflow "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/CapsFlowInputMethod" --self-test
print "Built: $app"
