#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project="$project_root/windows/VisionStack.Windows/VisionStack.Windows.csproj"
release_notes="$project_root/release/windows/0.9.0-beta.1.md"
version="${VISIONSTACK_WINDOWS_VERSION:-0.9.0-beta.1}"
rid="${1:-}"
package_mode="${2:-unsigned}"

case "$rid" in
  win-x64)
    pack_id="studio.yeluzi.visionstack.windows.x64"
    channel="win-x64-beta"
    ;;
  win-arm64)
    pack_id="studio.yeluzi.visionstack.windows.arm64"
    channel="win-arm64-beta"
    ;;
  *)
    echo "用法：$0 <win-x64|win-arm64> [unsigned|signed-candidate]" >&2
    exit 64
    ;;
esac

case "$package_mode" in
  unsigned)
    output_suffix="unsigned"
    sign_wrapper=""
    ;;
  signed-candidate)
    output_suffix="signed-candidate"
    sign_wrapper="${VISIONSTACK_WINDOWS_SIGN_WRAPPER:-}"
    if [[ -z "$sign_wrapper" ]]; then
      echo "signed-candidate 需要 VISIONSTACK_WINDOWS_SIGN_WRAPPER 指向绝对路径的可执行签名包装器。" >&2
      exit 78
    fi
    if [[ "$sign_wrapper" != /* ]]; then
      echo "签名包装器必须使用绝对路径：$sign_wrapper" >&2
      exit 65
    fi
    if [[ ! -f "$sign_wrapper" || ! -x "$sign_wrapper" ]]; then
      echo "签名包装器不存在或不可执行：$sign_wrapper" >&2
      exit 66
    fi
    ;;
  *)
    echo "未知打包模式：$package_mode" >&2
    echo "用法：$0 <win-x64|win-arm64> [unsigned|signed-candidate]" >&2
    exit 64
    ;;
esac

output_root="$project_root/dist/windows/$rid/$version-$output_suffix"
publish_dir="$output_root/publish"
release_dir="$output_root/release"

if [[ -e "$output_root" ]]; then
  echo "目标已存在，拒绝覆盖：$output_root" >&2
  exit 73
fi

mkdir -p "$publish_dir" "$release_dir"

dotnet restore "$project" --locked-mode
dotnet publish "$project" \
  --configuration Release \
  --runtime "$rid" \
  --self-contained true \
  --no-restore \
  --output "$publish_dir" \
  -p:DebugType=None \
  -p:DebugSymbols=false

velopack_dotnet_root="${VELOPACK_DOTNET_ROOT:-}"
if [[ -z "$velopack_dotnet_root" && -d /opt/homebrew/opt/dotnet@8/libexec ]]; then
  velopack_dotnet_root=/opt/homebrew/opt/dotnet@8/libexec
fi

vpk_args=(
  '[win]' pack
  --channel "$channel"
  --runtime "$rid"
  --packId "$pack_id"
  --packVersion "$version"
  --packDir "$publish_dir"
  --mainExe VisionStack.exe
  --packTitle "映栈 VisionStack"
  --packAuthors "Zhusi"
  --releaseNotes "$release_notes"
  --icon "$project_root/windows/VisionStack.Windows/Assets/AppIcon.ico"
  --outputDir "$release_dir"
)

if [[ "$package_mode" == "signed-candidate" ]]; then
  # 凭证不得进入命令行、模板、日志或项目文件。包装器只接收待签文件路径，
  # 并应使用已认证的受信任签名服务会话或系统秘密存储。
  sign_template="\"$sign_wrapper\" \"{{file}}\""
  vpk_args+=(--signTemplate "$sign_template")
fi

if [[ -n "$velopack_dotnet_root" ]]; then
  env DOTNET_ROOT="$velopack_dotnet_root" vpk "${vpk_args[@]}"
else
  vpk "${vpk_args[@]}"
fi

if [[ "$package_mode" == "signed-candidate" ]]; then
  printf '%s\n' \
    'schemaVersion=1' \
    "version=$version" \
    "rid=$rid" \
    'packagingMode=signed-candidate' \
    'authenticodeRequested=true' \
    'authenticodeTrusted=false' \
    'realWindowsValidated=false' \
    'publicReleaseAllowed=false' \
    'blockingReason=仍需在真实 Windows 验证签名链、时间戳、安装、升级、卸载、Defender 与 SmartScreen。' \
    > "$release_dir/WINDOWS_RELEASE_GATE.txt"
  echo "已生成待验收签名候选：$release_dir"
  echo "签名命令已执行，但在真实 Windows 验证信任链和运行门禁前仍不得公开发布。"
else
  printf '%s\n' \
    'schemaVersion=1' \
    "version=$version" \
    "rid=$rid" \
    'packagingMode=unsigned' \
    'authenticodeRequested=false' \
    'authenticodeTrusted=false' \
    'realWindowsValidated=false' \
    'publicReleaseAllowed=false' \
    'blockingReason=未完成受信任 Authenticode 与真实 Windows 验收。' \
    > "$release_dir/WINDOWS_RELEASE_GATE.txt"
  echo "已生成未签名候选：$release_dir"
  echo "不得公开发布，必须完成受信任 Authenticode 与真实 Windows 验收。"
fi
