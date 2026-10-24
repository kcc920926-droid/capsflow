#!/bin/zsh
set -euo pipefail
typeset -g setup_script_repo="${${(%):-%x}:A:h:h}"

setup_note() { print -r -- "$*"; }
setup_error() { print -ru2 -- "$*"; }
setup_help() {
    print 'CapsFlow 간편 설치: Install.command를 더블클릭하거나 zsh scripts/setup.sh 실행'
    print '  --check     설치 상태만 확인 (빌드·복사·등록·종료·설정창 열기 없음)'
    print '  --no-build  기존 dist 빌드 사용 (설치 ZIP에서는 기본 동작)'
    print '  --no-open   앱·설정 창을 열지 않음'
}
setup_validate() {
    local app="$1" identifier="$2" binary="$3"
    [[ -d "$app" && ! -L "$app" && -x "$app/Contents/MacOS/$binary" ]] || { setup_error "앱 파일이 올바르지 않습니다: $app"; return 1; }
    local found
    found=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist") || return 1
    [[ "$found" == "$identifier" ]] || { setup_error "예상과 다른 앱 ID: $app"; return 1; }
    [[ -d "$app/Contents/Resources/CapsFlow_InputCore.bundle" ]] || { setup_error "입력 사전 리소스가 없습니다: $app"; return 1; }
    /usr/bin/codesign --verify --deep --strict "$app" || return 1
}
setup_helper_call() { "$setup_helper" "$@"; }
setup_validate_helper() { /usr/bin/codesign --verify --strict "$setup_helper"; }
setup_register() { "$setup_ime/Contents/MacOS/CapsFlowInputMethod" --register "$setup_ime"; }
setup_open() { /usr/bin/open "$@"; }
setup_copy() { /usr/bin/ditto "$1" "$2"; }
setup_move() { /bin/mv "$1" "$2"; }
setup_same() { [[ -d "$2" ]] && /usr/bin/diff -qr -x .DS_Store "$1" "$2" >/dev/null 2>&1; }
setup_confirm_update() {
    setup_note '기존 자동 입력기를 교체합니다. 다른 앱의 조합 중인 글자도 모두 확정하고, 미전송 내용을 저장하세요.'
    if [[ ! -t 0 ]]; then
        setup_error '입력기 업데이트는 터미널에서 직접 확인해야 합니다. Install.command를 더블클릭해 다시 실행하세요.'
        return 3
    fi
    local answer=''
    read -r 'answer?입력을 모두 확정·저장했고 ABC/두벌식으로 전환했나요? 계속하려면 y 또는 예: ' || return 3
    [[ "$answer" == y || "$answer" == Y || "$answer" == 예 ]] || { setup_note '설치를 중단했습니다. 앱은 교체하지 않았습니다.'; return 3; }
}
setup_build() {
    local repo="$1"
    command -v xcrun >/dev/null && xcrun --find swiftc >/dev/null 2>&1 || {
        setup_error '빌드 도구가 없습니다. 먼저 xcode-select --install로 Command Line Tools를 설치하세요.'
        return 1
    }
    setup_note '[1/4] 두 앱 빌드 (처음에는 시간이 걸릴 수 있습니다)'
    zsh "$repo/scripts/build.sh" || return 1
    zsh "$repo/scripts/build-input-method.sh" || return 1
    setup_compile_helper "$repo" || return 1
}
setup_compile_helper() {
    local repo="$1"
    mkdir -p "$repo/dist" || return 1
    MACOSX_DEPLOYMENT_TARGET=13.0 xcrun swiftc -O -swift-version 5 "$repo/scripts/setup-helper.swift" -o "$repo/dist/CapsFlowSetupHelper" || return 1
    /usr/bin/codesign --force --sign - --identifier local.capsflow.setup-helper "$repo/dist/CapsFlowSetupHelper" || return 1
}
setup_release_lock() {
    if [[ "${setup_lock_owned:-0}" == 1 && -n "${setup_lock:-}" && -f "$setup_lock/pid" && "$(<"$setup_lock/pid")" == "$$" ]]; then
        /bin/rm -- "$setup_lock/pid"
        /bin/rmdir "$setup_lock" 2>/dev/null || true
        setup_lock_owned=0
    fi
}
setup_lock_install() {
    [[ ! -L "$setup_support" ]] || { setup_error '설치 상태 폴더가 심볼릭 링크입니다. 자동 설치를 중단합니다.'; return 1; }
    mkdir -p "$setup_support" || return 1
    setup_lock="$setup_support/install.lock"
    if ! /bin/mkdir "$setup_lock" 2>/dev/null; then
        local old_pid=''
        [[ -f "$setup_lock/pid" ]] && old_pid="$(<"$setup_lock/pid")"
        if [[ "$old_pid" == <-> ]] && ! kill -0 "$old_pid" 2>/dev/null; then
            /bin/rm -- "$setup_lock/pid" || return 1
            /bin/rmdir "$setup_lock" || return 1
            /bin/mkdir "$setup_lock" || return 1
        else
            setup_error '다른 설치가 진행 중이거나 잠금을 확인할 수 없습니다. 동시에 실행하지 마세요.'
            return 1
        fi
    fi
    print -r -- "$$" > "$setup_lock/pid"
    setup_lock_owned=1
    trap setup_release_lock EXIT
    trap 'exit 130' INT TERM
}
setup_backup_directory() {
    if [[ -z "${setup_backup:-}" ]]; then
        mkdir -p "$setup_support/Install Backups" || return 1
        setup_backup=$(/usr/bin/mktemp -d "$setup_support/Install Backups/install.XXXXXX") || return 1
        setup_note "기존 앱 보관 위치: $setup_backup"
    fi
}
setup_replace() {
    local source="$1" destination="$2" identifier="$3" binary="$4"
    local parent="${destination:h}" name="${destination:t}" stage previous=''
    [[ ! -L "$destination" && ! -L "$parent" ]] || { setup_error "심볼릭 링크 대상은 자동 교체하지 않습니다: $destination"; return 1; }
    mkdir -p "$parent" || return 1
    stage=$(/usr/bin/mktemp -d "$parent/.CapsFlow-install.XXXXXX") || return 1
    if ! setup_copy "$source" "$stage/$name" || ! setup_validate "$stage/$name" "$identifier" "$binary"; then
        setup_error "복사/검증 실패. 기존 앱은 그대로입니다. 임시 파일: $stage"
        return 1
    fi
    # Recheck immediately before touching an existing input method.
    if [[ "$binary" == CapsFlowInputMethod ]]; then
        setup_helper_call idle-ime "$destination" || return $?
    fi
    if [[ -e "$destination" ]]; then
        setup_backup_directory || return 1
        previous="$setup_backup/$name"
        setup_move "$destination" "$previous" || return 1
    fi
    if ! setup_move "$stage/$name" "$destination"; then
        if [[ -n "$previous" && ! -e "$destination" ]]; then
            setup_move "$previous" "$destination" || { setup_error "복구가 필요합니다. 기존 앱: $previous"; return 1; }
        fi
        setup_error '새 앱 이동 실패. 기존 앱이 있던 경우 원래 위치로 복구했습니다.'
        return 1
    fi
    /bin/rmdir "$stage" || true
}
setup_pending() {
    setup_note '입력기 파일 설치 완료 — macOS 입력 소스 추가가 필요합니다.'
    setup_note '시스템 설정 → 키보드 → 텍스트 입력 편집 → ＋ → 한국어 → CapsFlow 한국어 우선 → 추가'
    setup_note '목록에 없으면 작업 저장 후 로그아웃·로그인하고 추가하세요.'
    setup_note '그다음 같은 Install.command를 다시 실행하면 이어서 진행합니다. 기존 메뉴 앱은 바꾸지 않았습니다.'
    if (( setup_allow_open )); then
        setup_open 'x-apple.systempreferences:com.apple.Keyboard-Settings.extension' || true
    fi
    return 2
}
setup_check() {
    local repo="$1" user_root="$2" good=1
    local menu="$user_root/Applications/CapsFlow.app" ime="$user_root/Library/Input Methods/CapsFlowInputMethod.app"
    setup_note '상태 확인만 수행합니다. 앱·입력 소스·권한은 변경하지 않습니다.'
    if setup_validate "$menu" local.capsflow.app CapsFlow; then setup_note '메뉴 앱: 설치됨'; else setup_note '메뉴 앱: 없거나 검증 필요'; good=0; fi
    if setup_validate "$ime" local.inputmethod.capsflow CapsFlowInputMethod; then
        setup_note '자동 입력기 파일: 설치됨'
        if "$ime/Contents/MacOS/CapsFlowInputMethod" --is-enabled; then setup_note '입력 소스: 활성화됨'; else setup_note '입력 소스: 추가/재로그인 필요'; good=0; fi
    else setup_note '자동 입력기: 없거나 검증 필요'; good=0; fi
    setup_note '손쉬운 사용·입력 모니터링 승인 여부는 실행 중인 CapsFlow의 안내에서 확인하세요.'
    (( good )) || return 2
}
# Explicit arguments keep tests in disposable fixtures without ever overriding HOME.
setup_run() {
    local repo="$1" user_root="$2" build="$3" allow_open="$4"
    typeset -g setup_support="$user_root/Library/Application Support/CapsFlow"
    typeset -g setup_menu="$user_root/Applications/CapsFlow.app"
    typeset -g setup_ime="$user_root/Library/Input Methods/CapsFlowInputMethod.app"
    typeset -g setup_allow_open="$allow_open" setup_backup='' setup_lock='' setup_lock_owned=0
    local source_dir="$repo/dist"
    if [[ -d "$repo/apps" ]]; then
        source_dir="$repo/apps"
        typeset -g setup_helper="$repo/bin/CapsFlowSetupHelper"
        setup_note '[1/4] 설치 패키지 사용 (빌드 도구 불필요)'
    else
        if (( build )); then setup_build "$repo" || return 1; fi
        typeset -g setup_helper="$repo/dist/CapsFlowSetupHelper"
        if [[ ! -x "$setup_helper" ]]; then setup_compile_helper "$repo" || return 1; fi
    fi
    local source_menu="$source_dir/CapsFlow.app" source_ime="$source_dir/CapsFlowInputMethod.app"
    setup_validate "$source_menu" local.capsflow.app CapsFlow || return 1
    setup_validate "$source_ime" local.inputmethod.capsflow CapsFlowInputMethod || return 1
    [[ -x "$setup_helper" && ! -L "$setup_helper" ]] || { setup_error '설치 도우미가 없습니다.'; return 1; }
    setup_validate_helper || return 1
    [[ ! -L "$setup_menu" && ! -L "$setup_ime" ]] || { setup_error '기존 앱이 심볼릭 링크입니다. 자동 교체하지 않습니다.'; return 1; }
    [[ ( ! -e "$setup_menu" || -d "$setup_menu" ) && ( ! -e "$setup_ime" || -d "$setup_ime" ) ]] || { setup_error '앱 경로에 일반 파일이 있어 중단했습니다.'; return 1; }
    setup_lock_install || return 1
    local change_ime=1 change_menu=1
    setup_same "$source_ime" "$setup_ime" && change_ime=0
    setup_same "$source_menu" "$setup_menu" && change_menu=0
    setup_note '[2/4] 자동 입력기 설치·등록'
    if (( change_ime )); then
        setup_helper_call inactive-ime "$setup_ime" || return $?
        if [[ -d "$setup_ime" ]]; then setup_confirm_update || return $?; fi
        setup_helper_call stop-ime "$setup_ime" || return $?
        # A running menu utility could reselect Auto while its input method moves.
        setup_helper_call stop-menu "$setup_menu" || return $?
        setup_replace "$source_ime" "$setup_ime" local.inputmethod.capsflow CapsFlowInputMethod || return $?
    else setup_note '같은 입력기 파일은 교체하지 않습니다.'; fi
    if (( change_ime )) || ! setup_helper_call enabled; then
        local registered=0
        setup_register || registered=$?
        case "$registered" in
            0|2|4) ;;
            *) setup_error "입력기 등록에 실패했습니다 (상태 $registered). 메뉴 앱은 교체하지 않았습니다."; return 1 ;;
        esac
        if ! setup_helper_call enabled; then setup_pending; return $?; fi
    fi
    setup_note '[3/4] 메뉴 앱 설치'
    if (( change_menu )); then
        setup_helper_call stop-menu "$setup_menu" || return $?
        setup_replace "$source_menu" "$setup_menu" local.capsflow.app CapsFlow || return $?
    else setup_note '같은 메뉴 앱 파일은 교체하지 않습니다.'; fi
    setup_note '[4/4] 설치 완료'
    if (( setup_allow_open )); then setup_open "$setup_menu" || { setup_error "앱을 직접 열어주세요: $setup_menu"; return 1; }; fi
    setup_note 'macOS가 요청하면 CapsFlow의 손쉬운 사용·입력 모니터링을 직접 허용하세요.'
    setup_note '메뉴에서 ‘자동’을 선택한 뒤 dkssud + Space → 안녕, hello + Space → hello를 확인하세요.'
    setup_note '기존 설정은 보존했으며 입력 소스 강제 전환, 권한 DB 수정, 보안 해제는 하지 않았습니다.'
}
setup_main() {
    local repo="$setup_script_repo" build=1 allow_open=1 check=0 option
    for option in "$@"; do
        case "$option" in
            --check) check=1 ;; --no-build) build=0 ;; --no-open) allow_open=0 ;;
            --help|-h) setup_help; return 0 ;;
            *) setup_error "알 수 없는 옵션: $option"; return 1 ;;
        esac
    done
    [[ "$(uname -s)" == Darwin ]] || { setup_error 'macOS에서 실행하세요.'; return 1; }
    (( EUID != 0 )) || { setup_error 'sudo로 실행하지 마세요. 로그인한 사용자로 실행해야 합니다.'; return 1; }
    [[ "$HOME" == /* && "$HOME" != / && -d "$HOME" ]] || { setup_error '사용자 홈 경로를 확인할 수 없습니다.'; return 1; }
    if (( check )); then setup_check "$repo" "$HOME"; return $?; fi
    setup_run "$repo" "$HOME" "$build" "$allow_open"
}
if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then setup_main "$@"; fi
