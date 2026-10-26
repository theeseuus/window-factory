#!/bin/sh
set -eu
native_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$native_root/.build/ModuleCache"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/Core.swift" "$native_root/Tests/CoreTests.swift" -o "$native_root/.build/core-tests"
"$native_root/.build/core-tests" "$native_root/Resources/adapters.json"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/Core.swift" "$native_root/Sources/Store.swift" \
    "$native_root/Tests/StoreTests.swift" -o "$native_root/.build/store-tests"
"$native_root/.build/store-tests"
mise exec -- node "$native_root/Tests/signing-tests.cjs"
mise exec -- node "$native_root/Tests/install-tests.cjs"
mise exec -- node "$native_root/Tests/data-migration-tests.cjs"
mise exec -- node "$native_root/Tests/backup-retention-tests.cjs"
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/Core.swift" "$native_root/Sources/DirectGeometry.swift" \
    "$native_root/Tests/GeometryTests.swift" -o "$native_root/.build/geometry-tests"
"$native_root/.build/geometry-tests" "$native_root/Tests/Fixtures/legacy-geometry.json"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/Core.swift" "$native_root/Sources/DirectFrameApplication.swift" \
    "$native_root/Tests/FrameApplicationTests.swift" -o "$native_root/.build/frame-application-tests"
"$native_root/.build/frame-application-tests"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/Core.swift" "$native_root/Sources/DirectionalFocus.swift" \
    "$native_root/Tests/FocusTests.swift" -o "$native_root/.build/focus-tests"
"$native_root/.build/focus-tests" "$native_root/Tests/Fixtures/legacy-focus.json"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/Core.swift" "$native_root/Sources/StashGeometry.swift" \
    "$native_root/Tests/StashTests.swift" -o "$native_root/.build/stash-tests"
"$native_root/.build/stash-tests"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/WindowSwitching.swift" "$native_root/Tests/SwitcherTests.swift" \
    -o "$native_root/.build/switcher-tests"
"$native_root/.build/switcher-tests"

xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    "$native_root/Tests/ShortcutRegistryTests.m" -framework Carbon -framework Cocoa -o "$native_root/.build/shortcut-registry-tests"
"$native_root/.build/shortcut-registry-tests"

# Exercise the real AppKit document/viewport without showing or controlling windows.
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
    -c "$native_root/Sources/Bridge.m" -o "$native_root/.build/panel-test-bridge.o"
set --
for source in "$native_root"/Sources/*.swift; do
    [ "$(basename "$source")" = Main.swift ] || set -- "$@" "$source"
done
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    -import-objc-header "$native_root/Sources/Bridge.h" \
    "$@" "$native_root/Tests/SwitcherPanelTests.swift" "$native_root/.build/panel-test-bridge.o" \
    -framework Cocoa -framework ApplicationServices -framework Carbon -framework ScreenCaptureKit \
    -o "$native_root/.build/switcher-panel-tests"

"$native_root/.build/switcher-panel-tests"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    -import-objc-header "$native_root/Sources/Bridge.h" \
    "$@" "$native_root/Tests/AgentTests.swift" "$native_root/.build/panel-test-bridge.o" \
    -framework Cocoa -framework ApplicationServices -framework Carbon -framework ScreenCaptureKit \
    -o "$native_root/.build/agent-tests"
"$native_root/.build/agent-tests" "$native_root/Resources/adapters.json"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/Core.swift" "$native_root/Sources/AccordionGeometry.swift" \
    "$native_root/Tests/AccordionTests.swift" -o "$native_root/.build/accordion-tests"
"$native_root/.build/accordion-tests" "$native_root/Tests/Fixtures/legacy-accordion.json"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/Core.swift" "$native_root/Sources/SpaceMovement.swift" \
    "$native_root/Tests/SpaceMovementTests.swift" -o "$native_root/.build/space-movement-tests"
"$native_root/.build/space-movement-tests"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/SpaceIndicatorState.swift" "$native_root/Tests/SpaceIndicatorTests.swift" \
    -o "$native_root/.build/space-indicator-tests"
"$native_root/.build/space-indicator-tests"

xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    "$native_root/Sources/LaunchPolicy.swift" "$native_root/Tests/LaunchPolicyTests.swift" \
    -o "$native_root/.build/launch-policy-tests"
"$native_root/.build/launch-policy-tests"

# Tiling state machine uses an injected desktop; never observes or moves real windows.
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    -import-objc-header "$native_root/Sources/Bridge.h" \
    "$@" "$native_root/Tests/TilingTests.swift" "$native_root/.build/panel-test-bridge.o" \
    -framework Cocoa -framework ApplicationServices -framework Carbon -framework ScreenCaptureKit \
    -o "$native_root/.build/tiling-tests"
"$native_root/.build/tiling-tests"

# Single-window creation fixture never dispatches native application commands.
xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -warnings-as-errors \
    -module-cache-path "$native_root/.build/ModuleCache" \
    -import-objc-header "$native_root/Sources/Bridge.h" \
    "$@" "$native_root/Tests/NewWindowTests.swift" "$native_root/.build/panel-test-bridge.o" \
    -framework Cocoa -framework ApplicationServices -framework Carbon -framework ScreenCaptureKit \
    -o "$native_root/.build/new-window-tests"
"$native_root/.build/new-window-tests" "$native_root/Resources/adapters.json"
