#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LP_WORK="${LP_WORK:-/private/tmp/LecturePlayer-build-$UID}"
mkdir -p "$LP_WORK/modules" "$LP_WORK/cache"
export CLANG_MODULE_CACHE_PATH="$LP_WORK/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$LP_WORK/modules"
LP_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
LP_FLAGS=(-Xswiftc -F -Xswiftc "$LP_FRAMEWORKS" -Xlinker -rpath -Xlinker "$LP_FRAMEWORKS" -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib")
LP_PLUGIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"
if [[ ! -f "$LP_PLUGIN/libSwiftDataMacros.dylib" ]]; then
  LP_PLUGIN="/Applications/Swift Playground.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"
fi
if [[ ! -f "$LP_PLUGIN/libSwiftDataMacros.dylib" ]]; then
  echo 'Missing SwiftData compiler plugin. Install full Xcode, or use the existing Swift Playground toolchain.' >&2
  exit 1
fi
for LP_MACRO in SwiftData SwiftUI Foundation; do
 LP_FLAGS+=(-Xswiftc -load-plugin-library -Xswiftc "$LP_PLUGIN/lib${LP_MACRO}Macros.dylib")
done
LP_STAGE="$(mktemp -d "${TMPDIR:-/private/tmp/}LecturePlayerBuild.XXXXXX")"
cp Package.swift "$LP_STAGE/"
cp -R Sources Tests Samples "$LP_STAGE/"
# Compile a stable snapshot outside file-provider managed Documents.
cd "$LP_STAGE"
swift "$@" --package-path "$LP_STAGE" --build-system native --disable-sandbox --cache-path "$LP_WORK/cache" --scratch-path "$LP_WORK/native" "${LP_FLAGS[@]}"
