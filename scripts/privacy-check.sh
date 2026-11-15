#!/usr/bin/env bash
# ============================================================
# mac-native-ai 隐私 / 密钥扫描
#
#   用法:
#     scripts/privacy-check.sh --staged   # 扫描已 git add 的文件（pre-commit 调用）
#     scripts/privacy-check.sh --all      # 扫描全部已跟踪文件（发布前审计）
#     scripts/privacy-check.sh --worktree # 扫描工作区未忽略的文件
#     scripts/privacy-check.sh --files a.md b.rs
#
#   命中即 exit 1。误报可在行尾加 `privacy-check: allow` 豁免。
#   详见 docs/DEVELOPMENT.md「Privacy gate」。
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATTERNS="$ROOT/scripts/privacy-patterns.txt"
LOCAL_BLOCKLIST="$ROOT/.privacy-blocklist.local"
ALLOW_MARK="privacy-check: allow"

# 这些文件本身包含正则文本，跳过自扫描
SELF_FILES="scripts/privacy-patterns.txt scripts/privacy-check.sh"

MODE="${1:---staged}"
shift || true

if [ ! -f "$PATTERNS" ]; then
  echo "privacy-check: 找不到模式文件 $PATTERNS" >&2
  exit 2
fi

TMP_PAT="$(mktemp -t macai-privacy)"
TMP_FILES="$(mktemp -t macai-files)"
cleanup() { rm -f "$TMP_PAT" "$TMP_FILES"; }
trap cleanup EXIT

grep -v '^[[:space:]]*#' "$PATTERNS" 2>/dev/null | grep -v '^[[:space:]]*$' > "$TMP_PAT" || true
if [ -f "$LOCAL_BLOCKLIST" ]; then
  grep -v '^[[:space:]]*#' "$LOCAL_BLOCKLIST" 2>/dev/null | grep -v '^[[:space:]]*$' >> "$TMP_PAT" || true
fi

if [ ! -s "$TMP_PAT" ]; then
  echo "privacy-check: 没有生效的扫描模式，跳过"
  exit 0
fi

cd "$ROOT"

case "$MODE" in
  --staged)
    git diff --cached --name-only --diff-filter=ACM > "$TMP_FILES" 2>/dev/null
    ;;
  --all)
    git ls-files > "$TMP_FILES" 2>/dev/null
    ;;
  --worktree)
    git ls-files --cached --others --exclude-standard > "$TMP_FILES" 2>/dev/null
    ;;
  --files)
    printf '%s\n' "$@" > "$TMP_FILES"
    ;;
  *)
    echo "privacy-check: 未知模式 '$MODE'（支持 --staged / --all / --worktree / --files）" >&2
    exit 2
    ;;
esac

VIOLATIONS=0
SCANNED=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  # 跳过自扫描文件
  case " $SELF_FILES " in *" $f "*) continue ;; esac
  # 跳过二进制
  if ! grep -Iq . "$f" 2>/dev/null; then continue; fi
  SCANNED=$((SCANNED + 1))

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    lineno="${hit%%:*}"
    content="$(sed -n "${lineno}p" "$f" 2>/dev/null)"
    case "$content" in
      *"$ALLOW_MARK"*) continue ;;
    esac
    if [ "$VIOLATIONS" -eq 0 ]; then
      echo ""
      echo "⛔ privacy-check 命中敏感内容，提交已阻止："
      echo ""
    fi
    VIOLATIONS=$((VIOLATIONS + 1))
    # 截断显示，避免把完整密钥刷进终端历史
    printf '  %s:%s: %s\n' "$f" "$lineno" "$(printf '%s' "$content" | cut -c1-160)"
  done < <(grep -nE -f "$TMP_PAT" -- "$f" 2>/dev/null)
done < "$TMP_FILES"

if [ "$VIOLATIONS" -gt 0 ]; then
  echo ""
  echo "命中 $VIOLATIONS 处（已扫描 $SCANNED 个文件）。"
  echo "处理方式："
  echo "  1) 删除敏感内容，改用环境变量 / ~/ 路径 / 占位符；"
  echo "  2) 确属误报 → 在行尾加 '$ALLOW_MARK'；"
  echo "  3) 属本机专属模式（内网 IP、主机名）→ 加入 .privacy-blocklist.local。"
  echo "详见 docs/DEVELOPMENT.md「Privacy gate」。"
  echo ""
  exit 1
fi

echo "✅ privacy-check 通过（${MODE}，已扫描 ${SCANNED} 个文件）"
exit 0
