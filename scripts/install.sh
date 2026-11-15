#!/usr/bin/env bash
# 把 macai 装到 PATH（默认 ~/.local/bin，可用 MACAI_BIN_DIR 覆盖）。
# 幂等：重复执行只会刷新链接；卸载就删链接（脚本会打印命令）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${MACAI_BIN_DIR:-$HOME/.local/bin}"

[ -x "$ROOT/bin/macai" ] || { echo "先跑 scripts/build.sh 生成 bin/macai" >&2; exit 1; }

mkdir -p "$BIN_DIR"
ln -sf "$ROOT/bin/macai" "$BIN_DIR/macai"
chmod +x "$ROOT/bin/macai"

echo "已链接: $BIN_DIR/macai -> $ROOT/bin/macai"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo ""
    echo "⚠️ $BIN_DIR 不在 PATH 里。加到你的 shell 配置（一次性）："
    echo "   echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
    ;;
esac

echo ""
echo "自检: macai selftest"
echo "卸载: rm -f \"$BIN_DIR/macai\""
