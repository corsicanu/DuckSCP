#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs the unit tests. Works with Command Line Tools only (no Xcode):
# the swift-testing macro plugin lives in a subfolder SwiftPM does not search.
# Builds outside the repo because ~/Desktop may carry Finder xattrs that break codesign.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${SCRATCH:-$HOME/Library/Caches/DuckSCP-build}"
CLT=/Library/Developer/CommandLineTools
ARGS=(--scratch-path "$SCRATCH")
if [[ -d $CLT/usr/lib/swift/host/plugins/testing ]] && ! xcode-select -p | grep -q Xcode.app; then
  ARGS+=(-Xswiftc -plugin-path -Xswiftc $CLT/usr/lib/swift/host/plugins/testing
         -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks)
fi
swift test "${ARGS[@]}" "$@" 2>&1 | grep -v "ld: warning: search path"
