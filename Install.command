#!/bin/zsh
# Finder entry point. Uses only the current user's Applications and Library.
zsh "${0:A:h}/scripts/setup.sh" "$@"
capsflow_install_result=$?
if [[ -t 0 && -t 1 && "${1:-}" != "--check" && "${1:-}" != "--help" ]]; then
    print
    read -r '?Enter를 누르면 설치 안내를 마칩니다. '
fi
exit "$capsflow_install_result"
