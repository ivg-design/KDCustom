#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC=/Library/Developer/CommandLineTools/usr/bin
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
APP="$ROOT/build/Keydial Studio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$TC/clang" -isysroot "$SDK" -mmacosx-version-min=14.0 -Wall -Wextra -Werror \
  -c "$ROOT/Sources/K40USB.c" -o "$ROOT/build/K40USB-native.o"
SOURCES=("$ROOT/Sources/K40ButtonLayout.swift" "$ROOT/Sources/K40Decode.swift"
  "$ROOT/Sources/LabelPacket.swift" "$ROOT/Sources/K40Bluetooth.swift")
if [[ " ${*:-} " == *" --setup "* ]]; then
  SOURCES+=("$ROOT/Native/Setup/main.swift")
else
  SOURCES+=("$ROOT"/Native/Core/*.swift "$ROOT"/Native/Device/*.swift
    "$ROOT"/Native/MCP/*.swift "$ROOT"/Native/Platform/*.swift
    "$ROOT"/Native/UI/*.swift "$ROOT"/Native/App/*.swift)
fi
"$TC/swiftc" -sdk "$SDK" -target arm64-apple-macosx14.0 -warnings-as-errors -O \
  -framework AppKit -framework SwiftUI -framework IOKit -framework CoreBluetooth \
  -framework ApplicationServices -framework ServiceManagement -framework Carbon \
  -import-objc-header "$ROOT/Sources/K40USB.h" \
  "${SOURCES[@]}" "$ROOT/build/K40USB-native.o" -o "$APP/Contents/MacOS/KeydialStudio"
cp "$ROOT/Resources/kd-custom.png" "$APP/Contents/Resources/kd-custom.png"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
python3 - "$APP" "$ROOT" <<'PY'
import plistlib,sys
from pathlib import Path
app,root=map(Path,sys.argv[1:])
info={'CFBundleIdentifier':'life.mograph.KeydialStudio',
'CFBundleName':'KDCustom','CFBundleDisplayName':'KDCustom',
'CFBundleExecutable':'KeydialStudio','CFBundlePackageType':'APPL',
'CFBundleShortVersionString':'0.4.1','CFBundleVersion':'8',
'LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication',
'NSHighResolutionCapable':True,'CFBundleIconFile':'AppIcon','ProbeRepositoryPath':str(root),
'NSBluetoothAlwaysUsageDescription':'Connect to your Huion Keydial for button, dial, and screen control.'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
SIGNING_IDENTITY="${KDCUSTOM_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' | head -n 1)}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  printf '%s\n' 'Set KDCUSTOM_SIGNING_IDENTITY to a stable Developer ID identity.' >&2
  exit 1
fi
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
if [[ " ${*:-} " == *" --install "* ]]; then
  ditto "$APP" '/Applications/Keydial Studio.app'
fi
printf '%s\n' "$APP"
