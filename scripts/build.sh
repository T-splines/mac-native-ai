#!/usr/bin/env bash
# 构建 release 二进制到 bin/macai（产物目录已被 gitignore，不入库）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p bin
cp -f "$BIN_DIR/macai" bin/macai
cp -f "$BIN_DIR/macai-spec" bin/macai-spec
chmod +x bin/macai bin/macai-spec

# ⚠️ 签名失效的二进制会被 taskgated 直接 SIGKILL（崩溃报告里写 "Code Signature Invalid" /
# "Taskgated Invalid Signature"），表现是 `macai` 一启动就 "Killed: 9"。
# 构建被中断（链接完成但签名没写完）或复制过程都可能造成这种状态 —— 这里显式重签 ad-hoc。
codesign --force --sign - bin/macai bin/macai-spec >/dev/null 2>&1 || true
if ! ./bin/macai version >/dev/null 2>&1; then
  echo "⚠️ bin/macai 起不来（多半是签名失效）：删掉产物重链 → swift build -c release" >&2
  rm -f "$BIN_DIR/macai"
  swift build -c release
  cp -f "$BIN_DIR/macai" bin/macai
  codesign --force --sign - bin/macai >/dev/null 2>&1 || true
  ./bin/macai version >/dev/null 2>&1 || { echo "仍然起不来，请手工排查" >&2; exit 1; }
fi

echo "==> 版本"
./bin/macai version
echo "==> 产物"
ls -lh bin/macai | awk '{print "   " $9 "  " $5}'
echo "完成。装到 PATH:  scripts/install.sh"
