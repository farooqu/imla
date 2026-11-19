#!/bin/bash
# Runs the unit tests with the Command Line Tools' Swift Testing framework.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
F="$DEVELOPER_DIR/Library/Developer/Frameworks"
if [ -d "$F" ]; then
    # The Command Line Tools keep Testing.framework where swift test doesn't look.
    swift test --build-system native -Xswiftc "-F$F" -Xlinker "-F$F" \
        -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$DEVELOPER_DIR/Library/Developer/usr/lib" "$@"
else
    swift test --build-system native "$@"  # Xcode finds it itself.
fi
