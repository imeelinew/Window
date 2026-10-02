#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
work=$(mktemp -d /tmp/window-tests.XXXXXX)
trap 'rm -rf "$work"' EXIT
xcrun swiftc -swift-version 5 -default-isolation MainActor -warnings-as-errors -parse-as-library \
    "$root/Window/WindowGeometry.swift" "$root/Tests/WindowGeometryTests.swift" \
    -o "$work/WindowGeometryTests"
"$work/WindowGeometryTests"
xcrun swiftc -swift-version 5 -default-isolation MainActor -warnings-as-errors -parse-as-library \
    "$root/Window/KeyRepeat.swift" "$root/Tests/KeyRepeatTests.swift" \
    -o "$work/KeyRepeatTests"
"$work/KeyRepeatTests"
