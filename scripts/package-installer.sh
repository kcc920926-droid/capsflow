#!/bin/zsh
set -euo pipefail
capsflow_package_repo="${0:A:h:h}"
source "$capsflow_package_repo/scripts/setup.sh"
case "${1:-}" in
    ''|--no-build) ;;
    --help|-h) print 'Usage: zsh scripts/package-installer.sh [--no-build]'; exit 0 ;;
    *) print -ru2 -- '알 수 없는 옵션입니다. --no-build만 지원합니다.'; exit 1 ;;
esac
if [[ "${1:-}" != --no-build ]]; then setup_build "$capsflow_package_repo"; fi
setup_validate "$capsflow_package_repo/dist/CapsFlow.app" local.capsflow.app CapsFlow
setup_validate "$capsflow_package_repo/dist/CapsFlowInputMethod.app" local.inputmethod.capsflow CapsFlowInputMethod
typeset -g setup_helper="$capsflow_package_repo/dist/CapsFlowSetupHelper"
setup_validate_helper
capsflow_package_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$capsflow_package_repo/dist/CapsFlow.app/Contents/Info.plist")
capsflow_package_arch=$(/usr/bin/uname -m)
capsflow_package_stage=$(/usr/bin/mktemp -d "$capsflow_package_repo/dist/.installer-package.XXXXXX")
capsflow_package_root="$capsflow_package_stage/CapsFlow-Installer"
mkdir -p "$capsflow_package_root/apps" "$capsflow_package_root/bin" "$capsflow_package_root/scripts"
ditto "$capsflow_package_repo/dist/CapsFlow.app" "$capsflow_package_root/apps/CapsFlow.app"
ditto "$capsflow_package_repo/dist/CapsFlowInputMethod.app" "$capsflow_package_root/apps/CapsFlowInputMethod.app"
cp "$capsflow_package_repo/dist/CapsFlowSetupHelper" "$capsflow_package_root/bin/CapsFlowSetupHelper"
cp "$capsflow_package_repo/Install.command" "$capsflow_package_root/Install.command"
cp "$capsflow_package_repo/scripts/setup.sh" "$capsflow_package_root/scripts/setup.sh"
cp "$capsflow_package_repo/docs/INSTALLER.txt" "$capsflow_package_root/설치 안내.txt"
cp "$capsflow_package_repo/Sources/InputCore/Resources/ATTRIBUTION.txt" "$capsflow_package_root/사전 데이터 출처.txt"
chmod +x "$capsflow_package_root/Install.command" "$capsflow_package_root/scripts/setup.sh" "$capsflow_package_root/bin/CapsFlowSetupHelper"
capsflow_package_zip="$capsflow_package_repo/dist/CapsFlow-Installer-$capsflow_package_version-$capsflow_package_arch.zip"
ditto -c -k --sequesterRsrc --keepParent "$capsflow_package_root" "$capsflow_package_zip"
print -r -- "설치 ZIP 생성: $capsflow_package_zip"
print -r -- "포함된 스테이징 폴더: $capsflow_package_root"
print '이 작업은 설치 파일만 만들었습니다. 실행 중인 앱·입력 소스·권한은 바꾸지 않았습니다.'
