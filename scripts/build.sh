#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN=/Library/Developer/CommandLineTools/usr/bin
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
APP="$ROOT/build/K40 Probe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$TOOLCHAIN/swiftc" -sdk "$SDK" -target arm64-apple-macosx14.0 -O \
  -framework AppKit -framework IOKit -framework CoreBluetooth \
  "$ROOT/Sources/K40ButtonLayout.swift" "$ROOT/Sources/K40Decode.swift" "$ROOT/Sources/LabelPacket.swift" \
  "$ROOT/Sources/K40Bluetooth.swift" "$ROOT/Sources/main.swift" \
  -o "$APP/Contents/MacOS/K40Probe"
python3 - "$APP" "$ROOT" <<'PY'
import plistlib,sys
from pathlib import Path
app,root=map(Path,sys.argv[1:])
data={
 'CFBundleIdentifier':'life.mograph.K40Probe',
 'CFBundleName':'K40 Probe', 'CFBundleDisplayName':'K40 Probe',
 'CFBundleExecutable':'K40Probe', 'CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'0.2.0', 'CFBundleVersion':'2',
 'LSMinimumSystemVersion':'14.0', 'NSPrincipalClass':'NSApplication',
 'NSHighResolutionCapable':True, 'ProbeRepositoryPath':str(root)
}
data['NSBluetoothAlwaysUsageDescription']='Connect to your Huion K40 to test its buttons, dials, and temporary screen labels.'
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(data))
PY
SIGNING_IDENTITY="${KDCUSTOM_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' | head -n 1)}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  printf '%s\n' 'Set KDCUSTOM_SIGNING_IDENTITY to a stable Developer ID identity.' >&2
  exit 1
fi
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
