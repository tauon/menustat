#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build=$(mktemp -d "${TMPDIR:-/tmp}/menustat-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT

xcrun swiftc -O -warnings-as-errors -import-objc-header menustat-Bridging-Header.h \
    menustat/ProcMonitor.swift tests/ProcMonitorTests.swift -o "$test_build/proc-tests"
"$test_build/proc-tests"
for test in NetInfo NetProcStats; do
    xcrun clang -O2 -fobjc-arc -fmodules -Wall -Wextra -Werror -framework Foundation \
        "tests/${test}Tests.m" -o "$test_build/$test-tests"
    "$test_build/$test-tests"
done

# Compile and link the actual app sources, including Swift/Objective-C bridging.
# build.sh additionally packages the icon, Info.plist, and local signature.
for source in CPUInfo NetInfo NetProcStats; do
    xcrun clang -O2 -fobjc-arc -fmodules -Wall -Wextra -Werror \
        -mmacosx-version-min=15.0 -c "$source.m" -o "$test_build/$source.o"
done
xcrun swiftc -O -whole-module-optimization -warnings-as-errors \
    -target "$(uname -m)-apple-macosx15.0" -import-objc-header menustat-Bridging-Header.h \
    menustat/ProcMonitor.swift menustat/AppDelegate.swift \
    "$test_build/CPUInfo.o" "$test_build/NetInfo.o" "$test_build/NetProcStats.o" \
    -o "$test_build/menustat"
echo "PASS: optimized app compilation and linking (macOS 15 minimum)"

if [[ "${RUN_LIVE:-0}" == 1 ]]; then
    # The test supplies its own entry point instead of running the app's main.
    sed '/^@main$/d' menustat/AppDelegate.swift > "$test_build/AppDelegate.swift"
    xcrun swiftc -O -warnings-as-errors -import-objc-header menustat-Bridging-Header.h \
        menustat/ProcMonitor.swift "$test_build/AppDelegate.swift" tests/LiveSmoke.swift \
        "$test_build/CPUInfo.o" "$test_build/NetInfo.o" "$test_build/NetProcStats.o" \
        -o "$test_build/live-smoke"
    "$test_build/live-smoke"
fi
