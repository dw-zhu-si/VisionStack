#!/bin/zsh
# Compatibility entry point for community builds. Official signing is maintained separately.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
if [[ "${RELEASE_MODE:-local}" != local ]]; then
  print -u2 "此开源入口仅支持本机社区构建。衍生发行请建立使用自身 Bundle ID、权限与签名身份的发布流程。"
  exit 64
fi
exec "$ROOT_DIR/scripts/build_macos.sh"
