#!/bin/bash
# Community build only. Requires macOS 14+, Swift 6.2+ and Apple's local developer tools.
# No Apple account, certificate, notarization, installation or application launch.
# Ad-hoc signing is for local use; Gatekeeper and sandbox permissions need local validation.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${VERSION:-0.8.1}"
case "$version" in
  ''|*[!0-9.]*) echo 'VERSION must contain only digits and periods.' >&2; exit 64 ;;
esac
for tool in swift codesign ditto sips iconutil xattr; do
  command -v "$tool" >/dev/null || { echo "Missing local tool: $tool" >&2; exit 69; }
done
for required in Package.swift Packaging/PrivacyInfo.xcprivacy Packaging/VisionStack.entitlements Sources/VisionStack/Resources/AppIcon.png; do
  [[ -f "$project_root/$required" ]] || { echo "Missing repository input: $required" >&2; exit 66; }
done
# Assemble and sign outside Desktop/FileProvider; retain only an archive.
export COPYFILE_DISABLE=1
scratch="$(mktemp -d "${TMPDIR:-/tmp}/visionstack-community-build.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
cd "$project_root"
swift build -c release --product VisionStack --scratch-path "$scratch/build"
bin_dir="$(swift build -c release --show-bin-path --scratch-path "$scratch/build")"
resource_bundle="$bin_dir/VisionStack_VisionStack.bundle"
[[ -x "$bin_dir/VisionStack" && -d "$resource_bundle/ManagedSkills" ]] || {
  echo 'SwiftPM output is missing the executable or bundled capabilities.' >&2; exit 65;
}
app="$scratch/映栈社区版.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ditto --norsrc "$bin_dir/VisionStack" "$app/Contents/MacOS/VisionStack"
ditto --norsrc "$resource_bundle" "$app/Contents/Resources/VisionStack_VisionStack.bundle"
ditto --norsrc "$project_root/Sources/VisionStack/Resources/AppIcon.png" "$app/Contents/Resources/AppIcon.png"
ditto --norsrc "$project_root/Packaging/PrivacyInfo.xcprivacy" "$app/Contents/Resources/PrivacyInfo.xcprivacy"

iconset="$scratch/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$app/Contents/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$app/Contents/Resources/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>studio.yeluzi.visionstack.community</string>
<key>CFBundleName</key><string>映栈社区版</string>
<key>CFBundleDisplayName</key><string>映栈社区版</string>
<key>CFBundleExecutable</key><string>VisionStack</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>VisionStackDistributionProfile</key><string>public</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
# The community sandbox container is distinct from the official application's container.
# Do not add official provisioning profiles or team/application identifier entitlements.
xattr -cr "$app"
codesign --force --sign - --entitlements "$project_root/Packaging/VisionStack.entitlements" "$app"
codesign --verify --strict "$app"
mkdir -p "$project_root/dist/community"
output_dir="$(mktemp -d "$project_root/dist/community/build.XXXXXX")"
archive="$output_dir/VisionStack-community-$version.zip"
ditto -c -k --norsrc --keepParent "$app" "$archive"
# Verify the archive round trip in the same local scratch area before reporting success.
verify_dir="$scratch/archive-check"
mkdir -p "$verify_dir"
ditto -x -k "$archive" "$verify_dir"
codesign --verify --strict "$verify_dir/映栈社区版.app"
printf 'Local community ZIP: %s\n' "$archive"
printf '%s\n' 'Extract into a non-synced local folder for use. Example (run manually):'
printf '%s\n' 'community_run_dir="$(mktemp -d "${TMPDIR:-/tmp}/visionstack-community-run.XXXXXX")"'
printf 'ditto -x -k %q "$community_run_dir"\n' "$archive"
printf '%s\n' 'codesign --verify --strict "$community_run_dir/映栈社区版.app"'
printf '%s\n' 'open "$community_run_dir/映栈社区版.app"'
printf '%s\n' 'Ad-hoc signed only; not notarized, installed, launched, or validated by Gatekeeper.'
