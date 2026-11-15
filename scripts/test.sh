#!/usr/bin/env bash
# 全量验收：单测（spec）→ 各能力自检（selftest）→ 端到端断言（tests/e2e.sh）。
# 失败即非零退出，可直接接 CI / 提交前门禁。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILED=0
step() { echo ""; echo "===== $* ====="; }

step "构建（debug）"
if ! swift build; then
  echo "❌ 构建失败，停止（不使用旧产物跑测试）" >&2
  exit 2
fi
echo "构建完成"

step "单测（macai-spec）"
./.build/debug/macai-spec || FAILED=1

step "能力自检（macai selftest）"
./.build/debug/macai selftest || FAILED=1

step "端到端断言（tests/e2e.sh）"
./tests/e2e.sh || FAILED=1

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "✅ 全部通过"
else
  echo "❌ 有失败项（见上）"
fi
exit "$FAILED"
