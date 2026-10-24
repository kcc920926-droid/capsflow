#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ ! -x dist/CapsFlow.app/Contents/MacOS/CapsFlow ]]; then ./scripts/build.sh; fi
if ! ./dist/CapsFlow.app/Contents/MacOS/CapsFlow --native-input-method-ready; then
    print -u2 "Install/register CapsFlowInputMethod first. If absent in Keyboard settings, log out/in before continuing. No existing app was changed."
    exit 2
fi
./dist/CapsFlow.app/Contents/MacOS/CapsFlow --quit-running
destination="$HOME/Applications/CapsFlow.app"
mkdir -p "$HOME/Applications"
ditto "$PWD/dist/CapsFlow.app" "$destination"
codesign --verify --deep --strict "$destination"
open "$destination"
print "Installed and launched: $destination"
