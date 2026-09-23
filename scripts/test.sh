#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TC=/Library/Developer/CommandLineTools/usr/bin
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
mkdir -p build/tests
SWIFTC=("$TC/swiftc" -sdk "$SDK" -target arm64-apple-macosx14.0 -warnings-as-errors)
run() {
  local name="$1"; shift
  "${SWIFTC[@]}" "$@" "Tests/${name}Tests.swift" -o "build/tests/$name"
  "build/tests/$name"
}
run Decode Sources/K40ButtonLayout.swift Sources/K40Decode.swift
run Label Sources/K40ButtonLayout.swift Sources/LabelPacket.swift
run DeviceCommand Native/Device/K40DeviceCommands.swift
CORE=(Native/Core/Models.swift Native/Core/ProfileStore.swift)
run ProfileStore "${CORE[@]}"
run ActionEngine Native/Core/Models.swift Native/Core/ActionEngine.swift
run PhysicalInputState Native/Core/PhysicalInputState.swift
run MacModifierFlags Native/Core/Models.swift Native/Core/MacModifierFlags.swift
run FocusContext "${CORE[@]}"
run SmartDial "${CORE[@]}" Native/MCP/MCPTools.swift
run SmartHeuristics Native/Core/Models.swift Native/Core/SmartDialHeuristics.swift
run NumericAdjustment Native/Core/NumericAdjustment.swift
run NumericStepBuffer Native/Core/NumericAdjustment.swift Native/Core/NumericStepBuffer.swift
run NumericAdjustmentLease Native/Core/NumericAdjustmentLease.swift
run NumericFocusGeometry Native/Core/NumericFocusGeometry.swift
run RivePanelClassifier Native/Core/RivePanelClassifier.swift
run ShortcutRecorder Native/Core/Models.swift Native/UI/StudioTheme.swift Native/UI/BindingEditor.swift Native/UI/SmartDialEditor.swift -framework AppKit -framework SwiftUI
run ConfigurationService "${CORE[@]}" Native/Core/ConfigurationService.swift
run HuionImport "${CORE[@]}" Native/Core/HuionImporter.swift
run MCP "${CORE[@]}" Native/MCP/MCPTools.swift Native/MCP/MCPServer.swift
run LocalBridge "${CORE[@]}" Native/MCP/MCPTools.swift Native/MCP/LocalBridge.swift
"$TC/clang" -isysroot "$SDK" -mmacosx-version-min=14.0 -Wall -Wextra -Werror -c Sources/K40USB.c -o build/tests/K40USB.o
run DeviceController -import-objc-header Sources/K40USB.h -framework IOKit -framework CoreBluetooth \
  Native/Core/Models.swift Native/Device/K40DeviceCommands.swift Native/Device/DeviceController.swift \
  Sources/K40Bluetooth.swift Sources/K40ButtonLayout.swift Sources/K40Decode.swift Sources/LabelPacket.swift build/tests/K40USB.o
printf '%s\n' 'All focused suites passed.'
