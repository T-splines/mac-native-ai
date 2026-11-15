#!/usr/bin/env bash
# 一次性开发环境设置：装 git hooks（隐私门禁）+ 建本机专属扫描黑名单占位。
# 幂等，可重复执行。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit scripts/privacy-check.sh

if [ ! -f .privacy-blocklist.local ]; then
  cat > .privacy-blocklist.local <<'EOF'
# 本机专属扫描模式（已 gitignore，永不提交）
# 真实用户名 / 主机名 / 局域网标识等只在本机有意义的东西写这里，每行一个 POSIX ERE。
EOF
  echo "已创建 .privacy-blocklist.local（本机专属模式，不会进 git）"
fi

# 提交身份：仓库级 noreply，避免真实邮箱进历史
CURRENT_EMAIL="$(git config user.email || true)"
case "$CURRENT_EMAIL" in
  *@users.noreply.github.com) ;;
  *) echo "⚠️ 当前 user.email='$CURRENT_EMAIL' 不是 GitHub noreply 邮箱，本仓库将来公开，建议改掉。" ;;
esac

echo "完成：core.hooksPath=$(git config core.hooksPath)"
echo "手动全量扫描：./scripts/privacy-check.sh --all"
