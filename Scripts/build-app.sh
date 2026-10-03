#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/swift.sh build -c release
LP_WORK="${LP_WORK:-/private/tmp/LecturePlayer-build-$UID}"
LP_DEST="${LP_DEST:-$HOME/Applications/Lecture Player 0.8.5.app}"
LP_STAGE_APP="$(mktemp -d "${TMPDIR:-/private/tmp/}LecturePlayerPackage.XXXXXX")"
LP_APP="$LP_STAGE_APP/Lecture Player.app"
mkdir -p "$LP_APP/Contents/MacOS" "$LP_APP/Contents/Resources"
cp "$LP_WORK/native/arm64-apple-macosx/release/LecturePlayer" "$LP_APP/Contents/MacOS/LecturePlayer"
cp Resources/AppIcon.icns "$LP_APP/Contents/Resources/AppIcon.icns"
cat > "$LP_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LecturePlayer</string>
<key>CFBundleIdentifier</key><string>local.LecturePlayer</string>
<key>CFBundleName</key><string>Lecture Player</string>
<key>CFBundleDisplayName</key><string>Lecture Player</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.8.5</string>
<key>CFBundleVersion</key><string>20</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if xattr -p com.apple.FinderInfo "$LP_APP" >/dev/null 2>&1; then
  xattr -d com.apple.FinderInfo "$LP_APP"
fi
codesign --force --sign - "$LP_APP"
codesign --verify --deep --strict "$LP_APP"
LP_ZIP="$PWD/../LecturePlayer-0.8.5-app.zip"
ditto -c -k --norsrc --noextattr --keepParent "$LP_APP" "$LP_ZIP"
LP_VERIFY="$(mktemp -d "${TMPDIR:-/private/tmp/}LecturePlayerVerify.XXXXXX")"
ditto -x -k "$LP_ZIP" "$LP_VERIFY"
codesign --verify --deep --strict --verbose=2 "$LP_VERIFY/Lecture Player.app"
mkdir -p "$(dirname "$LP_DEST")"
if [[ -e "$LP_DEST" ]]; then
  LP_PREVIOUS="$(mktemp -d "${TMPDIR:-/private/tmp/}LecturePlayerPrevious.XXXXXX")"
  mv "$LP_DEST" "$LP_PREVIOUS/Lecture Player.app"
fi
ditto --noextattr --norsrc "$LP_APP" "$LP_DEST"
if codesign --verify --deep --strict "$LP_DEST"; then
  echo "Direct bundle verified: $LP_DEST"
else
  echo "Direct bundle has file-provider metadata; use the verified ZIP instead." >&2
fi
echo "Verified archive: $LP_ZIP"
