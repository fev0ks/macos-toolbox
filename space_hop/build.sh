#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_app="$task_root/SpaceHop.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
task_module_cache="${TMPDIR:-/tmp}/spacehop-module-cache"
xcrun swiftc -module-cache-path "$task_module_cache" -O -swift-version 5 -target arm64-apple-macosx13.0 \
  "$task_root"/Sources/*.swift -o "$task_app/Contents/MacOS/SpaceHop" \
  -framework AppKit -framework ApplicationServices -framework ServiceManagement -framework ScreenCaptureKit
cp "$task_root/Info.plist" "$task_app/Contents/Info.plist"
cp "$task_root"/LICENSE-* "$task_app/Contents/Resources/"
cp "$task_root/../LICENSE" "$task_app/Contents/Resources/LICENSE"
cp "$task_root/THIRD_PARTY_NOTICES.md" "$task_app/Contents/Resources/"
codesign --force --sign - --identifier local.spacehop.app "$task_app"
"$task_app/Contents/MacOS/SpaceHop" --self-test
print "Built: $task_app"
