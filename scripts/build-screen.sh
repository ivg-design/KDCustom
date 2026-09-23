#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC=/Library/Developer/CommandLineTools/usr/bin
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
mkdir -p "$ROOT/build"
"$TC/clang" -isysroot "$SDK" -mmacosx-version-min=14.0 -Wall -Wextra -Werror \
  -c "$ROOT/Sources/K40USB.c" -o "$ROOT/build/K40USB.o"
"$TC/swiftc" -sdk "$SDK" -target arm64-apple-macosx14.0 -O \
  -framework IOKit -framework CoreFoundation \
  -import-objc-header "$ROOT/Sources/K40USB.h" \
  "$ROOT/Sources/K40ButtonLayout.swift" "$ROOT/Sources/LabelPacket.swift" "$ROOT/Sources/ScreenCLI.swift" "$ROOT/build/K40USB.o" \
  -o "$ROOT/build/k40-screen"
"$TC/swiftc" -sdk "$SDK" "$ROOT/Sources/K40ButtonLayout.swift" "$ROOT/Sources/LabelPacket.swift" "$ROOT/Tests/LabelTests.swift" \
  -o "$ROOT/build/label-tests"
"$ROOT/build/label-tests"
"$TC/swiftc" -sdk "$SDK" "$ROOT/Sources/K40ButtonLayout.swift" "$ROOT/Sources/K40Decode.swift" "$ROOT/Tests/DecodeTests.swift" \
  -o "$ROOT/build/decode-tests"
"$ROOT/build/decode-tests"
