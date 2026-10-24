#!/bin/zsh
set -euo pipefail
capsflow_test_repo="${0:A:h:h}"
source "$capsflow_test_repo/scripts/setup.sh"
capsflow_test_root=$(mktemp -d /tmp/capsflow-installer-tests.XXXXXX)
integer test_passed=0 test_failed=0
assert() { if ! "$@"; then print -ru2 -- "ASSERT: $*"; exit 1; fi; }
eq() { [[ "$1" == "$2" ]]; }
fixture_app() {
    local app="$1" ident="$2" name="$3" version="$4"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/CapsFlow_InputCore.bundle"
    print -r -- "$ident" > "$app/Contents/Info.plist"
    print -r -- "$version" > "$app/Contents/test-version"
    print '#!/bin/zsh' > "$app/Contents/MacOS/$name"
    print '[[ "$1" == --is-enabled && -f "$CAPSFLOW_FIXTURE_STATE/enabled" ]]' >> "$app/Contents/MacOS/$name"
    chmod +x "$app/Contents/MacOS/$name"
}
fixture() {
    case_dir=$(mktemp -d "$capsflow_test_root/case.XXXXXX")
    repo="$case_dir/repo"; user_dir="$case_dir/user"; control="$case_dir/control"
    mkdir -p "$repo/apps" "$repo/bin" "$user_dir/Library/Preferences" "$control"
    print keep-me > "$user_dir/Library/Preferences/local.capsflow.app.plist"
    fixture_app "$repo/apps/CapsFlow.app" local.capsflow.app CapsFlow new-menu
    fixture_app "$repo/apps/CapsFlowInputMethod.app" local.inputmethod.capsflow CapsFlowInputMethod new-ime
    print '#!/bin/zsh' > "$repo/bin/CapsFlowSetupHelper"; chmod +x "$repo/bin/CapsFlowSetupHelper"
    : > "$control/events"
    export CAPSFLOW_FIXTURE_STATE="$control"
}
# Substitute ONLY system/API boundaries; real copy, rename, diff, lock and backup
# functions operate in disposable fixture roots. HOME is never reassigned.
setup_validate() {
    [[ -d "$1" && ! -L "$1" && -x "$1/Contents/MacOS/$3" && "$(<"$1/Contents/Info.plist")" == "$2" && ! -f "$control/invalid" ]]
}
setup_validate_helper() { [[ ! -f "$control/bad-helper" ]]; }
setup_build() { print build >> "$control/events"; [[ ! -f "$control/build-fail" ]]; }
setup_compile_helper() { print compile >> "$control/events"; return 1; }
setup_open() { print -r -- "open $1" >> "$control/events"; }
setup_confirm_update() { print confirm-update >> "$control/events"; [[ ! -f "$control/cancel-update" ]] || return 3; }
setup_register() {
    print register >> "$control/events"
    if [[ -f "$control/register-fail" ]]; then return 3; fi
    if [[ -f "$control/pending" ]]; then return "$(<"$control/pending")"; fi
    : > "$control/enabled"
}
setup_helper_call() {
    print -r -- "$1" >> "$control/events"
    case "$1" in
        enabled) [[ -f "$control/enabled" ]] ;;
        inactive-ime) [[ ! -f "$control/active" ]] || return 3 ;;
        stop-ime|idle-ime) [[ ! -f "$control/active" && ! -f "$control/ime-busy" ]] || return 3 ;;
        stop-menu) [[ ! -f "$control/menu-busy" ]] || return 3 ;;
        *) return 1 ;;
    esac
}
run_setup() {
    result=0
    setup_run "$repo" "$user_dir" "${1:-0}" "${2:-1}" > "$case_dir/output" 2>&1 || result=$?
    setup_release_lock
}
same_settings() { assert eq "$(<"$user_dir/Library/Preferences/local.capsflow.app.plist")" keep-me; }
install_old() {
    fixture_app "$user_dir/Applications/CapsFlow.app" local.capsflow.app CapsFlow old-menu
    fixture_app "$user_dir/Library/Input Methods/CapsFlowInputMethod.app" local.inputmethod.capsflow CapsFlowInputMethod old-ime
}
check_fresh() {
    fixture; run_setup
    assert eq "$result" 0
    assert eq "$(<"$setup_menu/Contents/test-version")" new-menu
    assert eq "$(<"$setup_ime/Contents/test-version")" new-ime
    assert /usr/bin/grep -q register "$control/events"
    assert /usr/bin/grep -q "open $setup_menu" "$control/events"
    same_settings
}
check_pending_resume() {
    fixture; install_old; print 2 > "$control/pending"; run_setup
    assert eq "$result" 2
    assert eq "$(<"$setup_menu/Contents/test-version")" old-menu
    assert eq "$(<"$setup_ime/Contents/test-version")" new-ime
    /bin/rm "$control/pending"; : > "$control/enabled"; : > "$control/active"; : > "$control/events"
    run_setup
    assert eq "$result" 0
    assert eq "$(<"$setup_menu/Contents/test-version")" new-menu
    assert test "$(/usr/bin/grep -c stop-ime "$control/events" || true)" -eq 0
    same_settings
}
check_active_blocked() {
    fixture; install_old; : > "$control/active"; run_setup
    assert eq "$result" 3
    assert eq "$(<"$setup_menu/Contents/test-version")" old-menu
    assert eq "$(<"$setup_ime/Contents/test-version")" old-ime
    assert test "$(/usr/bin/grep -c stop-menu "$control/events" || true)" -eq 0
    same_settings
}
check_backups() {
    fixture; install_old; : > "$control/enabled"; run_setup
    assert eq "$result" 0
    assert eq "$(<"$setup_backup/CapsFlow.app/Contents/test-version")" old-menu
    assert eq "$(<"$setup_backup/CapsFlowInputMethod.app/Contents/test-version")" old-ime
    assert /usr/bin/grep -q register "$control/events"
    same_settings
}
check_idempotent() {
    fixture; run_setup; : > "$control/events"; : > "$control/active"; run_setup
    assert eq "$result" 0
    assert test "$(/usr/bin/grep -c stop- "$control/events" || true)" -eq 0
    assert test "$(/usr/bin/grep -c register "$control/events" || true)" -eq 0
    assert eq "$setup_backup" ''
    same_settings
}
check_menu_busy() {
    fixture; install_old; /usr/bin/ditto "$repo/apps/CapsFlowInputMethod.app" "$user_dir/Library/Input Methods/CapsFlowInputMethod.app"
    : > "$control/enabled"; : > "$control/menu-busy"; run_setup
    assert test "$result" -ne 0
    assert eq "$(<"$setup_menu/Contents/test-version")" old-menu
    same_settings
}
check_ime_busy() {
    fixture; install_old; : > "$control/ime-busy"; run_setup
    assert test "$result" -ne 0
    assert eq "$(<"$setup_ime/Contents/test-version")" old-ime
    same_settings
}
check_invalid_bundle() {
    fixture; install_old; : > "$control/invalid"; run_setup
    assert eq "$result" 1
    assert eq "$(<"$user_dir/Applications/CapsFlow.app/Contents/test-version")" old-menu
    assert test ! -e "$user_dir/Library/Application Support/CapsFlow/install.lock"
    same_settings
}
check_bad_helper() {
    fixture; install_old; : > "$control/bad-helper"; run_setup
    assert eq "$result" 1
    assert eq "$(<"$setup_ime/Contents/test-version")" old-ime
    same_settings
}
check_register_failed() {
    fixture; install_old; : > "$control/register-fail"; run_setup
    assert eq "$result" 1
    assert eq "$(<"$setup_menu/Contents/test-version")" old-menu
    assert eq "$(<"$setup_backup/CapsFlowInputMethod.app/Contents/test-version")" old-ime
    same_settings
}
check_symlink_refused() {
    fixture; mkdir -p "$user_dir/Applications" "$case_dir/other-app"
    /bin/ln -s "$case_dir/other-app" "$user_dir/Applications/CapsFlow.app"
    run_setup
    assert eq "$result" 1
    assert test -L "$user_dir/Applications/CapsFlow.app"
    same_settings
}
check_no_open() {
    fixture; run_setup 0 0; assert eq "$result" 0
    assert test "$(/usr/bin/grep -c '^open ' "$control/events" || true)" -eq 0
}
check_read_only() {
    fixture; result=0; setup_check "$repo" "$user_dir" > "$case_dir/output" 2>&1 || result=$?
    assert eq "$result" 2
    assert test ! -e "$user_dir/Library/Application Support"
    assert test ! -s "$control/events"
    same_settings
}
check_source_build() {
    fixture; /bin/mv "$repo/apps" "$repo/dist"; /bin/mv "$repo/bin/CapsFlowSetupHelper" "$repo/dist/"
    run_setup 1 0
    assert eq "$result" 0
    assert /usr/bin/grep -q '^build$' "$control/events"
}
check_atomic_restore() {
    fixture; install_old; : > "$control/enabled"
    setup_move() {
        if [[ "$1" == */.CapsFlow-install.*/CapsFlowInputMethod.app ]]; then return 1; fi
        /bin/mv "$1" "$2"
    }
    run_setup
    assert eq "$result" 1
    assert eq "$(<"$setup_ime/Contents/test-version")" old-ime
    assert eq "$(<"$setup_menu/Contents/test-version")" old-menu
    same_settings
}
check_copy_failed() {
    fixture; install_old
    setup_copy() { return 1; }
    run_setup
    assert eq "$result" 1
    assert eq "$(<"$setup_ime/Contents/test-version")" old-ime
    assert eq "$(<"$setup_menu/Contents/test-version")" old-menu
    same_settings
}
check_live_lock() {
    fixture
    local lock="$user_dir/Library/Application Support/CapsFlow/install.lock"
    mkdir -p "$lock"; print -r -- "$$" > "$lock/pid"
    run_setup
    assert eq "$result" 1
    assert eq "$(<"$lock/pid")" "$$"
    assert test ! -s "$control/events"
}
check_unknown_lock_files() {
    fixture
    local lock="$user_dir/Library/Application Support/CapsFlow/install.lock"
    mkdir -p "$lock"; print 999999999 > "$lock/pid"; print keep > "$lock/unrecognized"
    run_setup
    assert eq "$result" 1
    assert eq "$(<"$lock/unrecognized")" keep
}
check_pending_no_open() {
    fixture; print 2 > "$control/pending"; run_setup 0 0
    assert eq "$result" 2
    assert test "$(/usr/bin/grep -c '^open ' "$control/events" || true)" -eq 0
    same_settings
}
check_menu_only() {
    fixture; install_old; /usr/bin/ditto "$repo/apps/CapsFlowInputMethod.app" "$user_dir/Library/Input Methods/CapsFlowInputMethod.app"
    : > "$control/enabled"; : > "$control/active"; run_setup
    assert eq "$result" 0
    assert test "$(/usr/bin/grep -c stop-ime "$control/events" || true)" -eq 0
    assert eq "$(<"$setup_menu/Contents/test-version")" new-menu
    same_settings
}
check_regular_file() {
    fixture; mkdir -p "$user_dir/Applications"; print keep-notes > "$user_dir/Applications/CapsFlow.app"
    run_setup
    assert eq "$result" 1
    assert eq "$(<"$user_dir/Applications/CapsFlow.app")" keep-notes
}
check_fresh_process_pending() {
    fixture; print 4 > "$control/pending"; run_setup
    assert eq "$result" 2
    assert test ! -e "$setup_menu"
    assert eq "$(<"$setup_ime/Contents/test-version")" new-ime
}
check_update_cancelled() {
    fixture; install_old; : > "$control/cancel-update"; run_setup
    assert eq "$result" 3
    assert eq "$(<"$setup_ime/Contents/test-version")" old-ime
    assert eq "$(<"$setup_menu/Contents/test-version")" old-menu
    assert test "$(/usr/bin/grep -c '^stop-' "$control/events" || true)" -eq 0
    same_settings
}
for name in fresh pending_resume active_blocked backups idempotent menu_busy ime_busy invalid_bundle bad_helper register_failed symlink_refused no_open read_only source_build atomic_restore copy_failed live_lock unknown_lock_files pending_no_open menu_only regular_file fresh_process_pending update_cancelled; do
    if ( "check_$name" ); then print "PASS $name"; ((test_passed+=1)); else print "FAIL $name"; ((test_failed+=1)); fi
done
print "$test_passed installer scenarios passed; $test_failed failed. Fixtures: $capsflow_test_root"
(( test_failed == 0 ))
