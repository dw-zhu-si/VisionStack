#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
VERSION="${VERSION:-0.8.1}"
BUILD_NUMBER="${BUILD_NUMBER:-27}"
RELEASE_MODE="${RELEASE_MODE:-local}"
BUNDLE_ID="studio.yeluzi.visionstack"
TEAM_ID="${TEAM_ID:-}"
EXPECTED_APP_IDENTIFIER="$TEAM_ID.$BUNDLE_ID"
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-}"
APP_STORE_IDENTITY="${APP_STORE_IDENTITY:-}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP_STORE_PROVISIONING_PROFILE="${APP_STORE_PROVISIONING_PROFILE:-}"
RESOURCE_BUNDLE_NAME="VisionStack_VisionStack.bundle"
STAGE_DIR="$(mktemp -d /tmp/visionstack-package.XXXXXX)"
PUBLIC_SOURCE_DIR="$STAGE_DIR/source"
BUILD_DIR="$STAGE_DIR/swiftpm-build/release"
BUILD_RESOURCE_BUNDLE="$BUILD_DIR/$RESOURCE_BUNDLE_NAME"
APP_DIR="$STAGE_DIR/映栈.app"
CONTENTS_DIR="$APP_DIR/Contents"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
EFFECTIVE_ENTITLEMENTS="$STAGE_DIR/VisionStack.entitlements"
APP_STORE_PROFILE_PLIST="$STAGE_DIR/AppStoreProvisioningProfile.plist"
SIGNED_ENTITLEMENTS="$STAGE_DIR/SignedApp.entitlements"
trap 'rm -rf "$STAGE_DIR"' EXIT

fail() {
  print -u2 "$1"
  exit 2
}

case "$RELEASE_MODE" in
  local)
    CHANNEL="local"
    DISTRIBUTION_PROFILE="personal"
    ARTIFACT_STEM="VisionStack-$VERSION-macos-arm64-local"
    ;;
  github|developer-id|distribution)
    CHANNEL="github"
    DISTRIBUTION_PROFILE="public"
    ARTIFACT_STEM="VisionStack-$VERSION-macos-arm64"
    RELEASE_MODE="github"
    ;;
  app-store)
    CHANNEL="app-store"
    DISTRIBUTION_PROFILE="public"
    ARTIFACT_STEM="VisionStack-$VERSION-macos-arm64-app-store"
    ;;
  *)
    fail "RELEASE_MODE 仅支持 local、github 或 app-store"
    ;;
esac

OUTPUT_DIR="$ROOT_DIR/dist/macos/$CHANNEL"
case "$OUTPUT_DIR" in
  "$ROOT_DIR/dist/macos/"*) ;;
  *) fail "拒绝清理未解析的输出目录：$OUTPUT_DIR" ;;
esac

verify_identity() {
  local identity="$1"
  [[ -n "$identity" ]] || fail "正式签名需要显式配置签名身份"
  security find-identity -v -p codesigning | grep -F -- "$identity" >/dev/null \
    || fail "Keychain 中找不到签名身份：$identity"
}

verify_installer_identity() {
  [[ -n "$INSTALLER_IDENTITY" ]] || fail "正式安装包需要显式配置 INSTALLER_IDENTITY"
  security find-identity -v | grep -F -- "$INSTALLER_IDENTITY" >/dev/null \
    || fail "Keychain 中找不到安装包签名身份：$INSTALLER_IDENTITY"
}

verify_app_store_profile() {
  local profile="$1"
  [[ -n "$profile" && -r "$profile" ]] \
    || fail "App Store 打包需要 APP_STORE_PROVISIONING_PROFILE 指向可读的 Mac App Store 描述文件"
  security cms -D -i "$profile" > "$APP_STORE_PROFILE_PLIST" \
    || fail "无法解析 App Store provisioning profile"
  plutil -lint "$APP_STORE_PROFILE_PLIST" >/dev/null

  local application_identifier team_identifier profile_platform
  application_identifier="$(plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - "$APP_STORE_PROFILE_PLIST" 2>/dev/null || true)"
  team_identifier="$(plutil -extract 'Entitlements.com\.apple\.developer\.team-identifier' raw -o - "$APP_STORE_PROFILE_PLIST" 2>/dev/null || true)"
  profile_platform="$(plutil -extract Platform.0 raw -o - "$APP_STORE_PROFILE_PLIST" 2>/dev/null || true)"
  [[ "$application_identifier" == "$EXPECTED_APP_IDENTIFIER" ]] \
    || fail "provisioning profile 的 application-identifier 与 $BUNDLE_ID 不匹配"
  [[ "$team_identifier" == "$TEAM_ID" ]] \
    || fail "provisioning profile 的 Team ID 与当前签名团队不匹配"
  [[ "$profile_platform" == "OSX" ]] \
    || fail "provisioning profile 不是 macOS 分发描述文件"
  if plutil -extract ProvisionedDevices raw -o - "$APP_STORE_PROFILE_PLIST" >/dev/null 2>&1; then
    fail "provisioning profile 是设备安装描述文件，不可用于 Mac App Store"
  fi

  /usr/bin/swift -e '
    import Foundation
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let data = try Data(contentsOf: url)
    let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    guard let profile = value as? [String: Any], let expiration = profile["ExpirationDate"] as? Date, expiration > Date() else {
        FileHandle.standardError.write(Data("provisioning profile 已过期或缺少有效期\n".utf8))
        exit(2)
    }
  ' "$APP_STORE_PROFILE_PLIST" || fail "provisioning profile 有效期检查失败"
}

verify_resource_layout() {
  local candidate="$1"
  local managed_root="$candidate/Contents/Resources/$RESOURCE_BUNDLE_NAME/ManagedSkills"
  local actual_directories
  local expected_directories
  [[ -x "$candidate/Contents/MacOS/VisionStack" ]] || fail "App 缺少可执行文件：$candidate"
  [[ -r "$candidate/Contents/Resources/AppIcon.icns" ]] || fail "App 缺少 AppIcon.icns：$candidate"
  [[ -r "$candidate/Contents/Resources/AppIcon.png" ]] || fail "App 缺少图标源 PNG：$candidate"
  [[ -r "$candidate/Contents/Resources/PrivacyInfo.xcprivacy" ]] || fail "App 缺少隐私清单：$candidate"
  [[ -r "$candidate/Contents/Resources/$RESOURCE_BUNDLE_NAME/AppIcon.png" ]] || fail "App 缺少 SwiftPM 资源包：$candidate"
  if [[ "$RELEASE_MODE" == app-store ]]; then
    [[ -r "$candidate/Contents/embedded.provisionprofile" ]] || fail "App Store 包缺少 embedded.provisionprofile"
  fi

  expected_directories=$'GCMinimalZinePoster\nImpeccable\nPhotoRelicEditorial\nPortraitReshootDirection\nTaste\nVisionStackImageFoundation\nVisionStackVideoFoundation'
  actual_directories="$(find "$managed_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)"
  [[ "$actual_directories" == "$expected_directories" ]] \
    || fail "公开包内置能力目录不符合白名单：\n$actual_directories"

  local skill_directory
  for skill_directory in ${(f)expected_directories}; do
    [[ -r "$managed_root/$skill_directory/SKILL.md" ]] || fail "内置能力缺少 SKILL.md：$skill_directory"
    [[ -r "$managed_root/$skill_directory/LICENSE" ]] || fail "内置能力缺少 LICENSE：$skill_directory"
    [[ -r "$managed_root/$skill_directory/SOURCE.md" ]] || fail "内置能力缺少 SOURCE.md：$skill_directory"
  done

  [[ ! -e "$managed_root/AIGCPromptAesthetic" ]] || fail "公开包不得包含未授权的 AIGC Prompt Aesthetic 资源"
  [[ ! -e "$managed_root/GatheredScenesZine" ]] || fail "公开包不得包含仅限个人非商业用途的 Gathered Scenes 资源"
  [[ ! -e "$candidate/$RESOURCE_BUNDLE_NAME" ]] || fail "App 根目录不能包含未密封的 SwiftPM 资源包"
  if rg -n --hidden '(ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|sk-[A-Za-z0-9]{20,})' "$candidate/Contents" >/dev/null; then
    fail "公开包疑似包含凭证或私钥"
  fi
  if rg -a -n '/Users/' "$candidate/Contents/MacOS/VisionStack" >/dev/null; then
    fail "公开包可执行文件包含开发机用户路径"
  fi
}

create_icon() {
  local source_png="$ROOT_DIR/Sources/VisionStack/Resources/AppIcon.png"
  local iconset="$STAGE_DIR/AppIcon.iconset"
  mkdir -p "$iconset"
  sips -z 16 16 "$source_png" --out "$iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$source_png" --out "$iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$source_png" --out "$iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$source_png" --out "$iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset" -o "$CONTENTS_DIR/Resources/AppIcon.icns"
}

prepare_info_plist() {
  local sdk_version sdk_build xcode_version xcode_build xcode_numeric build_machine
  sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
  sdk_build="$(xcrun --sdk macosx --show-sdk-build-version)"
  xcode_version="$(xcodebuild -version | awk 'NR==1 {print $2}')"
  xcode_build="$(xcodebuild -version | awk 'NR==2 {print $3}')"
  xcode_numeric="$(print "$xcode_version" | awk -F. '{printf "%d%d%d", $1, $2, ($3 == "" ? 0 : $3)}')"
  build_machine="$(sw_vers -buildVersion)"

  cp "$ROOT_DIR/Packaging/Info.plist.template" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :BuildMachineOSBuild $build_machine" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :DTPlatformBuild $sdk_build" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :DTPlatformVersion $sdk_version" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :DTSDKBuild $sdk_build" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :DTSDKName macosx$sdk_version" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :DTXcode $xcode_numeric" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :DTXcodeBuild $xcode_build" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Set :VisionStackDistributionProfile $DISTRIBUTION_PROFILE" "$INFO_PLIST"
  plutil -lint "$INFO_PLIST" >/dev/null
}

prepare_entitlements() {
  if [[ "$RELEASE_MODE" == app-store ]]; then
    cp "$ROOT_DIR/Packaging/VisionStackAppStore.entitlements" "$EFFECTIVE_ENTITLEMENTS"
  else
    cp "$ROOT_DIR/Packaging/VisionStack.entitlements" "$EFFECTIVE_ENTITLEMENTS"
  fi
  plutil -lint "$EFFECTIVE_ENTITLEMENTS" >/dev/null
}

if [[ "$RELEASE_MODE" == app-store ]]; then
  [[ -n "$TEAM_ID" ]] || fail "App Store 打包需要显式配置 TEAM_ID 并核对权限模板"
  verify_app_store_profile "$APP_STORE_PROVISIONING_PROFILE"
fi

mkdir -p "$PUBLIC_SOURCE_DIR"
COPYFILE_DISABLE=1 ditto --norsrc "$ROOT_DIR/Package.swift" "$PUBLIC_SOURCE_DIR/Package.swift"
if [[ -f "$ROOT_DIR/Package.resolved" ]]; then
  COPYFILE_DISABLE=1 ditto --norsrc "$ROOT_DIR/Package.resolved" "$PUBLIC_SOURCE_DIR/Package.resolved"
fi
COPYFILE_DISABLE=1 ditto --norsrc "$ROOT_DIR/Sources" "$PUBLIC_SOURCE_DIR/Sources"
COPYFILE_DISABLE=1 ditto --norsrc "$ROOT_DIR/Tests" "$PUBLIC_SOURCE_DIR/Tests"

cd "$PUBLIC_SOURCE_DIR"
mkdir -p .build/ModuleCache .build/SwiftPMCache
CLANG_MODULE_CACHE_PATH="$PUBLIC_SOURCE_DIR/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PUBLIC_SOURCE_DIR/.build/ModuleCache" \
SWIFTPM_CUSTOM_CACHE_PATH="$PUBLIC_SOURCE_DIR/.build/SwiftPMCache" \
swift build -c release --product VisionStack --disable-sandbox --scratch-path "$STAGE_DIR/swiftpm-build"
cd "$ROOT_DIR"

[[ -x "$BUILD_DIR/VisionStack" ]] || fail "Release 构建未生成可执行文件"
[[ -d "$BUILD_RESOURCE_BUNDLE" ]] || fail "Release 构建未生成 SwiftPM 资源包"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR" "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BUILD_DIR/VisionStack" "$CONTENTS_DIR/MacOS/VisionStack"
chmod +x "$CONTENTS_DIR/MacOS/VisionStack"
COPYFILE_DISABLE=1 ditto --norsrc "$BUILD_RESOURCE_BUNDLE" "$CONTENTS_DIR/Resources/$RESOURCE_BUNDLE_NAME"
cp "$ROOT_DIR/Sources/VisionStack/Resources/AppIcon.png" "$CONTENTS_DIR/Resources/AppIcon.png"
cp "$ROOT_DIR/Packaging/PrivacyInfo.xcprivacy" "$CONTENTS_DIR/Resources/PrivacyInfo.xcprivacy"
create_icon
prepare_info_plist
prepare_entitlements
if [[ "$RELEASE_MODE" == app-store ]]; then
  cp "$APP_STORE_PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
fi
verify_resource_layout "$APP_DIR"
xattr -cr "$APP_DIR"

signing_status="ad-hoc"
notarization_status="not-required-local"
case "$RELEASE_MODE" in
  local)
    codesign --force --sign - "$APP_DIR"
    ;;
  github)
    verify_identity "$DEVELOPER_ID_IDENTITY"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
      || fail "无法使用公证钥匙串配置：$NOTARY_PROFILE"
    codesign --force --options runtime --timestamp --entitlements "$EFFECTIVE_ENTITLEMENTS" --sign "$DEVELOPER_ID_IDENTITY" "$APP_DIR"
    signing_status="developer-id"
    ;;
  app-store)
    verify_identity "$APP_STORE_IDENTITY"
    verify_installer_identity
    codesign --force --options runtime --timestamp --entitlements "$EFFECTIVE_ENTITLEMENTS" --sign "$APP_STORE_IDENTITY" "$APP_DIR"
    signing_status="apple-distribution"
    notarization_status="performed-by-app-store"
    ;;
esac

codesign --verify --strict --verbose=2 "$APP_DIR"
if [[ "$RELEASE_MODE" == app-store ]]; then
  codesign -d --entitlements :- "$APP_DIR" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
  plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null
  SIGNED_APPLICATION_IDENTIFIER="$(plutil -extract 'com\.apple\.application-identifier' raw -o - "$SIGNED_ENTITLEMENTS")"
  [[ "$SIGNED_APPLICATION_IDENTIFIER" == "$EXPECTED_APP_IDENTIFIER" ]] \
    || fail "签名后的 application-identifier 不正确"
  SIGNED_SANDBOX_ENABLED="$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$SIGNED_ENTITLEMENTS")"
  [[ "$SIGNED_SANDBOX_ENABLED" == "true" ]] \
    || fail "签名后的 App 未启用 App Sandbox"
fi
if [[ "$RELEASE_MODE" == local ]]; then
  plutil -create xml1 "$OUTPUT_DIR/CODE_SIGN_ENTITLEMENTS.plist"
else
  codesign -d --entitlements :- "$APP_DIR" > "$OUTPUT_DIR/CODE_SIGN_ENTITLEMENTS.plist" 2>/dev/null
fi
plutil -lint "$OUTPUT_DIR/CODE_SIGN_ENTITLEMENTS.plist" >/dev/null

ZIP_PATH="$OUTPUT_DIR/$ARTIFACT_STEM.zip"
DMG_PATH="$OUTPUT_DIR/$ARTIFACT_STEM.dmg"
PKG_PATH="$OUTPUT_DIR/$ARTIFACT_STEM.pkg"

if [[ "$RELEASE_MODE" == github ]]; then
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_DIR" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  spctl -a -vv -t execute "$APP_DIR"
  rm -f "$ZIP_PATH"
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_DIR" "$ZIP_PATH"

  DMG_ROOT="$STAGE_DIR/dmg-root"
  mkdir -p "$DMG_ROOT"
  COPYFILE_DISABLE=1 ditto --norsrc "$APP_DIR" "$DMG_ROOT/映栈.app"
  hdiutil create -quiet -ov -volname "映栈 $VERSION" -srcfolder "$DMG_ROOT" -format UDZO "$DMG_PATH"
  codesign --force --timestamp --sign "$DEVELOPER_ID_IDENTITY" "$DMG_PATH"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
  hdiutil verify "$DMG_PATH" >/dev/null
  notarization_status="app-and-dmg-accepted-stapled-gatekeeper-accepted"
elif [[ "$RELEASE_MODE" == app-store ]]; then
  productbuild --component "$APP_DIR" /Applications --sign "$INSTALLER_IDENTITY" "$PKG_PATH"
  pkgutil --check-signature "$PKG_PATH" > "$OUTPUT_DIR/PKG_SIGNATURE.txt"
else
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_DIR" "$ZIP_PATH"
fi

if [[ "$RELEASE_MODE" == local ]]; then
  # Desktop/FileProvider 可能立即给展开的 .app 重新附加 FinderInfo，破坏密封签名。
  # 本机渠道因此也只保留已签名 ZIP；需要运行时在非受管临时目录展开。
  APP_OUTPUT_PATH="not-retained-use-signed-zip"
else
  APP_OUTPUT_PATH="not-retained-use-signed-package"
fi

if [[ -f "$ZIP_PATH" ]]; then
  ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
  print "$ZIP_SHA256  ${ZIP_PATH:t}" > "$ZIP_PATH.sha256"
else
  ZIP_SHA256="not-created"
fi
if [[ -f "$DMG_PATH" ]]; then
  DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  print "$DMG_SHA256  ${DMG_PATH:t}" > "$DMG_PATH.sha256"
else
  DMG_SHA256="not-created"
fi
if [[ -f "$PKG_PATH" ]]; then
  PKG_SHA256="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"
  print "$PKG_SHA256  ${PKG_PATH:t}" > "$PKG_PATH.sha256"
else
  PKG_SHA256="not-created"
fi

print "resource_bundle=$RESOURCE_BUNDLE_NAME\nmanaged_skills=7\nmanaged_agents=6\npublic_safe_profile=$DISTRIBUTION_PROFILE\nprivacy_manifest=present" > "$OUTPUT_DIR/RESOURCE_COPY_LOG.txt"
profile_status="not-required"
[[ "$RELEASE_MODE" == app-store ]] && profile_status="embedded-and-verified"
print "packaging_artifact_version=3\nversion=$VERSION\nbuild_number=$BUILD_NUMBER\nrelease_mode=$RELEASE_MODE\ndistribution_profile=$DISTRIBUTION_PROFILE\napp_path=${APP_OUTPUT_PATH:t}\nzip_path=${ZIP_PATH:t}\ndmg_path=${DMG_PATH:t}\npkg_path=${PKG_PATH:t}\nzip_sha256=$ZIP_SHA256\ndmg_sha256=$DMG_SHA256\npkg_sha256=$PKG_SHA256\nresource_bundle_status=verified\napp_icon_packaged=true\nprivacy_manifest_packaged=true\nprovisioning_profile_status=$profile_status\npublic_skill_allowlist_verified=true\nsafe_swiftpm_resource_copy=true\nsigning_status=$signing_status\nnotarization_status=$notarization_status\ninstallation_status=not-installed\nFINAL_STATUS=success" > "$OUTPUT_DIR/PACKAGE_MANIFEST.txt"
print "$OUTPUT_DIR"
