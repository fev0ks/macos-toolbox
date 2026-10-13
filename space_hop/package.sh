#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_app="$task_root/SpaceHop.app"
task_artifacts="$task_root/artifacts"
task_stage=$(mktemp -d "${TMPDIR:-/tmp}/spacehop-package.XXXXXX")
trap 'rm -rf -- "$task_stage"' EXIT

"$task_root/build.sh"
codesign --verify --strict "$task_app"
task_arch=$(lipo -archs "$task_app/Contents/MacOS/SpaceHop")
if [[ "$task_arch" != "arm64" ]]; then
  print -u2 "Expected arm64 application, got: $task_arch"
  exit 1
fi
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")
task_name="SpaceHop-$task_version-arm64"
task_dmg="$task_artifacts/$task_name.dmg"
task_zip="$task_artifacts/$task_name.zip"
task_checksums="$task_artifacts/SpaceHop-$task_version-SHA256SUMS.txt"
# Do not silently replace artifacts that may already have been published.
for task_path in "$task_dmg" "$task_zip" "$task_checksums"; do
  if [[ -e "$task_path" ]]; then
    print -u2 "Artifact already exists: $task_path"
    exit 1
  fi
done

mkdir -p "$task_artifacts" "$task_stage/dmg" "$task_stage/$task_name"
ditto "$task_app" "$task_stage/dmg/SpaceHop.app"
ln -s /Applications "$task_stage/dmg/Applications"
cp "$task_root/INSTALL.txt" "$task_stage/dmg/INSTALL.txt"
hdiutil create -volname "SpaceHop $task_version" -srcfolder "$task_stage/dmg" -format UDZO -fs HFS+ "$task_dmg"
hdiutil verify "$task_dmg"
ditto "$task_app" "$task_stage/$task_name/SpaceHop.app"
cp "$task_root/INSTALL.txt" "$task_stage/$task_name/INSTALL.txt"
ditto -c -k --sequesterRsrc --keepParent "$task_stage/$task_name" "$task_zip"
(
  cd "$task_artifacts"
  shasum -a 256 "$task_name.dmg" "$task_name.zip" > "$task_checksums"
)
print "Packaged: $task_dmg"
print "Packaged: $task_zip"
print "Checksums: $task_checksums"
