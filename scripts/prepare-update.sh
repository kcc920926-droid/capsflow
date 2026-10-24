#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
capsflow_update_arch=$(uname -m)
capsflow_update_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - dist/CapsFlow.app/Contents/Info.plist)
capsflow_update_zip="$PWD/dist/CapsFlow-Installer-$capsflow_update_version-$capsflow_update_arch.zip"
capsflow_update_signer="$PWD/dist/CapsFlowUpdateSigner"
if [[ ! -x "$capsflow_update_signer" || scripts/update-signer.swift -nt "$capsflow_update_signer" ]]; then
    MACOSX_DEPLOYMENT_TARGET=13.0 xcrun swiftc -O -swift-version 5 scripts/update-signer.swift -o "$capsflow_update_signer"
    codesign --force --sign - --identifier local.capsflow.update-signer "$capsflow_update_signer"
fi
# No automatic key creation here: an approved, existing publisher Keychain key is required.
capsflow_update_public=$("$capsflow_update_signer" --public-key)
capsflow_update_payload="$PWD/dist/update-payload-$capsflow_update_version-$capsflow_update_arch.json"
capsflow_update_manifest="$PWD/dist/latest-$capsflow_update_arch.json"
xcrun swift scripts/create-update-payload.swift "$capsflow_update_zip" "$PWD/dist/CapsFlow.app" "$capsflow_update_arch" "$capsflow_update_public" "$capsflow_update_payload"
"$capsflow_update_signer" --sign "$capsflow_update_payload" "$capsflow_update_manifest"
"$PWD/dist/CapsFlow.app/Contents/MacOS/CapsFlow" --verify-update-bundle "$capsflow_update_manifest" "$capsflow_update_zip"
(cd dist && shasum -a 256 "${capsflow_update_zip:t}") > "$capsflow_update_zip.sha256"
print -r -- "서명 매니페스트 준비 완료: $capsflow_update_manifest"
print '아직 공개 피드는 바꾸지 않았습니다. 릴리스 ZIP을 먼저 공개·검증한 뒤 updates/latest-CPU.json에 매니페스트를 반영하세요.'
