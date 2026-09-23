#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TC=/Library/Developer/CommandLineTools/usr/bin
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
APP="$ROOT/build/Keydial Studio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$TC/swiftc" -sdk "$SDK" -target arm64-apple-macosx14.0 -O \
  -framework AppKit -framework IOKit -framework CoreBluetooth \
  -framework ApplicationServices -framework ServiceManagement \
  "$ROOT/Sources/K40ButtonLayout.swift" "$ROOT/Sources/K40Decode.swift" \
  "$ROOT/Sources/LabelPacket.swift" "$ROOT/Sources/K40Bluetooth.swift" \
  "$ROOT/Native/App/main.swift" -o "$APP/Contents/MacOS/KeydialStudio"
python3 - "$APP" "$ROOT" <<'PY'
import plistlib,sys
from pathlib import Path
app,root=map(Path,sys.argv[1:])
info={'CFBundleIdentifier':'life.mograph.KeydialStudio',
'CFBundleName':'Keydial Studio','CFBundleDisplayName':'Keydial Studio',
'CFBundleExecutable':'KeydialStudio','CFBundlePackageType':'APPL',
'CFBundleShortVersionString':'0.3.0','CFBundleVersion':'3',
'LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication',
'NSHighResolutionCapable':True,'ProbeRepositoryPath':str(root),
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
if [[ "${1:-}" == "--install" ]]; then
  ditto "$APP" '/Applications/Keydial Studio.app'
fi
printf '%s\n' "$APP"
