#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift run CoreChecks
swift run UpdateChecks
swift build --product CapsFlow
bin_dir="$(swift build --show-bin-path)"
"$bin_dir/CapsFlow" --runtime-checks
"$bin_dir/CapsFlow" --ui-smoke-test
swift build --product CapsFlowInputMethod
"$bin_dir/CapsFlowInputMethod" --self-test
