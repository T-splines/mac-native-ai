#!/usr/bin/env bash
# 端到端验收：对**真实二进制**跑真实调用，逐项断言输出内容（不是"跑完没报错就算过"）。
# 用法: ./tests/e2e.sh [macai 路径]   默认用 ./.build/debug/macai
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACAI="${1:-$ROOT/.build/debug/macai}"
# 可选：外部 fixture 生成器（同时产出 .expect.txt 已知字符串侧车）。有则做 2560×1440 基准对照，没有就 skip。
# 把生成器路径写进 MACAI_EXPECT_PROBE；默认不指向任何仓库，保持公开仓库自包含。
EXPECT_PROBE="${MACAI_EXPECT_PROBE:-}"
WORK="$(mktemp -d -t macai-e2e)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  ⚠️  %s\n' "$1"; }
head2() { printf '\n▶︎ %s\n' "$1"; }

assert_contains() { # <文本> <子串> <标签>
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) bad "$3 — 期望包含 '$2'，实际: $(printf '%s' "$1" | head -c 200)" ;;
  esac
}
assert_eq() { # <实际> <期望> <标签>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — 期望 '$2'，实际 '$1'"; fi
}

assert_ok() { # <退出码> <标签>
  if [ "$1" = "0" ]; then ok "$2"; else bad "$2 — 退出码 $1"; fi
}

# 带超时的运行：只把子进程退出码打到 stdout，子进程的 stdout/stderr 落到指定文件
# （避免「退出码」和「子进程输出」混进同一个重定向）。挂住的用例在超时里被 kill，
# 退出码是 124（断言必然失败），而整个 e2e 不会被拖死 —— 这正是「不挂住」要验证的事。
RUN_TIMEOUT="${MACAI_E2E_TIMEOUT:-20}"
run_timed() { # <标准输入文件> <标签> <stdout 文件> <stderr 文件> -- <命令...>
  local stdin_file="$1" label="$2" out_file="$3" err_file="$4"; shift 5
  python3 - "$stdin_file" "$label" "$RUN_TIMEOUT" "$out_file" "$err_file" "$@" <<'PY'
import subprocess, sys
stdin_file, label = sys.argv[1], sys.argv[2]
timeout, out_file, err_file = float(sys.argv[3]), sys.argv[4], sys.argv[5]
cmd = sys.argv[6:]
with open(stdin_file, "rb") as handle, open(out_file, "wb") as out, open(err_file, "wb") as err:
    try:
        code = subprocess.run(cmd, stdin=handle, stdout=out, stderr=err, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        err.write(("%s 超时未返回（%ss）\n" % (label, timeout)).encode())
        code = 124
print(code)
PY
}

# 等值比较：两侧 JSON 除 file（<stdin> vs 真实路径）与 ms 外必须完全一致，lines 逐元素相等。
# 命中数 = 与 fixture 侧车 .expect.txt 逐行匹配上的行数（两侧必须一致）。
assert_json_equivalent() { # <路径侧 JSON 文件> <stdin 侧 JSON 文件> <期望路径> <标签>
  local result
  result="$(python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path_json, stdin_json, expected_path = sys.argv[1], sys.argv[2], sys.argv[3]
a = json.load(open(path_json))["data"]
b = json.load(open(stdin_json))["data"]
def strip(d):
    d = dict(d)
    d.pop("ms", None)
    return d
a2, b2 = strip(a), strip(b)
b2["file"] = a2["file"]
same = a2 == b2 and a["lines"] == b["lines"]
problems = []
if not same:
    problems.append("keys=%s" % sorted(set(a) ^ set(b)))
if a2["file"] != expected_path:
    problems.append("file=%s" % a2["file"])
if b["file"] != "<stdin>":
    problems.append("stdin file=%s" % b["file"])
if len(a["lines"]) != len(b["lines"]):
    problems.append("行数 %d vs %d" % (len(a["lines"]), len(b["lines"])))
print("TRUE" if not problems else "FALSE: " + "; ".join(problems[:4]))
PY
)"
  case "$result" in
    TRUE) ok "$4" ;;
    *) bad "$4 — $result" ;;
  esac
}

assert_hits() { # <JSON 文件> <期望侧车> <期望命中> <标签>
  # 命中口径：大小写不敏感 + 各类破折号归一后**整行相等**。
  # （实测严格逐字匹配是 17/20：`--frames` 被识别成 `-frames`、`0xDEADBEEF` 成 `OxDEADBEEF`、
  #  `kTCCService` 成 `KTCCService` —— 都是 Vision 的正常混淆，不是本入口的缺陷。
  #  这里要验证的是「两侧一致」，不是「OCR 绝对准确」，所以口径写死在这里。）
  local result
  result="$(python3 - "$1" "$2" <<'PY'
import json, sys
def norm(s):
    s = s.strip().casefold()
    for ch in "\u2010\u2011\u2012\u2013\u2014\u2015\u2212":
        s = s.replace(ch, "-")
    return s
data = json.load(open(sys.argv[1]))["data"]
expected = [l.strip() for l in open(sys.argv[2]) if l.strip()]
found = {norm(l["text"]) for l in data["lines"]}
hits = sum(1 for e in expected if norm(e) in found)
print("%d/%d" % (hits, len(expected)))
PY
)"
  assert_eq "$result" "$3" "$4"
}
assert_json() { # <json文本> <python 表达式(用 d 表示解析后的对象)> <标签>
  local result
  result="$(printf '%s' "$1" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception as e:
    print('PARSE_ERROR:'+str(e)); raise SystemExit
print('TRUE' if ($2) else 'FALSE')
" 2>&1)"
  case "$result" in
    TRUE) ok "$3" ;;
    *) bad "$3 — $result" ;;
  esac
}

assert_jsonl() { # <JSONL 文本> <python 表达式(用 d 表示解析后的一行行对象列表)> <标签>
  local result
  result="$(printf '%s' "$1" | python3 -c "
import json,sys
try:
    d=[json.loads(l) for l in sys.stdin if l.strip()]
except Exception as e:
    print('PARSE_ERROR:'+str(e)); raise SystemExit
print('TRUE' if ($2) else 'FALSE')
" 2>&1)"
  case "$result" in
    TRUE) ok "$3" ;;
    *) bad "$3 — $result" ;;
  esac
}

# 帧流构造器：与 `macai help` 里给出的 Python 一行**同源**（{ [u32 大端长度][字节] } … [u32 大端 0]）
frames_of() { # <图片...> → stdout 帧流
  python3 -c 'import struct,sys
d=[open(p,"rb").read() for p in sys.argv[1:]]
sys.stdout.buffer.write(b"".join(struct.pack(">I",len(x))+x for x in d)+struct.pack(">I",0))' "$@"
}

# 帧流与多路径的等值比较：页数一致、每页除 file/ms 外完全相等、lines 逐元素相等、file 记 <stdin>#N。
assert_pages_equivalent() { # <多路径 JSON> <帧流 JSON> <期望帧数> <标签>
  local result
  result="$(python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path_json, frame_json, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
a = json.load(open(path_json))["data"]["pages"]
b = json.load(open(frame_json))["data"]["pages"]
def strip(page):
    page = dict(page)
    page.pop("ms", None)
    page.pop("file", None)
    return page
problems = []
if len(a) != count:
    problems.append("多路径侧页数 %d != %d" % (len(a), count))
if len(b) != count:
    problems.append("帧流侧页数 %d != %d" % (len(b), count))
if len(a) == len(b):
    if [strip(x) for x in a] != [strip(x) for x in b]:
        problems.append("pages（除 file/ms 外）不等值")
    if [x["lines"] for x in a] != [x["lines"] for x in b]:
        problems.append("lines 逐元素不等（text/confidence/box）")
    for i, page in enumerate(b):
        if page["file"] != "<stdin>#%d" % (i + 1):
            problems.append("第 %d 页 file=%s" % (i + 1, page["file"]))
print("TRUE" if not problems else "FALSE: " + "; ".join(problems[:4]))
PY
)"
  case "$result" in
    TRUE) ok "$4" ;;
    *) bad "$4 — $result" ;;
  esac
}

[ -x "$MACAI" ] || { echo "找不到可执行文件: $MACAI（先 scripts/build.sh）" >&2; exit 1; }
echo "被测二进制: $MACAI"
"$MACAI" version

# ---------------------------------------------------------------- 参数与退出码
head2 "命令行契约"
assert_eq "$("$MACAI" version | awk '{print $1}')" "macai" "version 输出"
"$MACAI" definitely-not-a-command >/dev/null 2>&1
assert_eq "$?" "1" "未知命令退出码 = 1"
"$MACAI" ocr >/dev/null 2>&1
assert_eq "$?" "1" "缺参数退出码 = 1"
"$MACAI" ocr /nonexistent-file-xyz.png >/dev/null 2>&1
assert_eq "$?" "2" "文件不存在退出码 = 2"
"$MACAI" ocr /nonexistent-file-xyz.png --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print("TRUE" if d["ok"] is False and "error" in d else "FALSE")' > "$WORK/err.txt"
assert_eq "$(cat "$WORK/err.txt")" "TRUE" "失败时 --json 仍输出合法 JSON 信封"

# ---------------------------------------------------------------- OCR（独立 fixture）
head2 "OCR"
# fixture 用系统工具链独立生成（textutil→qlmanage），与 selftest 里的 CoreGraphics 绘图路径不同源
printf 'MACAI-E2E OCR FIXTURE\nserial: 987654321\n' > "$WORK/fixture.txt"
if textutil -convert rtf -output "$WORK/fixture.rtf" "$WORK/fixture.txt" 2>/dev/null \
   && qlmanage -t -s 900 -o "$WORK" "$WORK/fixture.rtf" >/dev/null 2>&1 \
   && [ -f "$WORK/fixture.rtf.png" ]; then
  OCR_TEXT="$("$MACAI" ocr "$WORK/fixture.rtf.png" --lang en-US)"
  assert_contains "$OCR_TEXT" "MACAI-E2E" "识别出英文标题"
  assert_contains "$OCR_TEXT" "987654321" "识别出数字串"
  OCR_JSON="$("$MACAI" ocr "$WORK/fixture.rtf.png" --lang en-US --json)"
  assert_json "$OCR_JSON" "d['ok'] and d['data']['line_count']>=2" "JSON 信封与行数"
  assert_json "$OCR_JSON" "all(len(l['box'])==4 for l in d['data']['lines'])" "每行都有像素 bbox"
else
  skip "系统工具链生成图文 fixture 失败（未阻断 OCR 断言的其他路径）"
fi

# ---------------------------------------------------------------- OCR 的 stdin 入口（路径写 -）
head2 "OCR stdin 入口"
# ① '-' 出现两次 = 参数错（stdin 只能读一次），必须在读 stdin 之前就拒绝
OCR_DUP_OUT="$("$MACAI" ocr - - 2>&1)"
assert_eq "$?" "1" "ocr - - 退出码 = 1"
assert_contains "$OCR_DUP_OUT" "只能出现一次" "ocr - - 说明原因"
# ② 空 stdin = 参数错（管道没送来任何字节）
: > "$WORK/empty.bin"
assert_eq "$(run_timed "$WORK/empty.bin" "空 stdin" "$WORK/ocr-empty.json" "$WORK/ocr-empty.err" -- "$MACAI" ocr - --json)" "1" "空 stdin 退出码 = 1（不挂住）"
assert_contains "$(cat "$WORK/ocr-empty.json")" "stdin 是空的" "空 stdin 报明确错误"
# ③ 非图片字节 = 运行失败（能建源但解不出图，不能漏成崩溃/空结果）
printf 'not an image\n' > "$WORK/garbage.bin"
assert_eq "$(run_timed "$WORK/garbage.bin" "垃圾字节" "$WORK/ocr-garbage.json" "$WORK/ocr-garbage.err" -- "$MACAI" ocr - --json)" "2" "非图片字节退出码 = 2"
assert_contains "$(cat "$WORK/ocr-garbage.json")" "无法解析图片" "非图片字节报明确错误"
# ④ TTY（pty）下 ocr - ：stdin 是终端不是管道 → 参数错且**立即返回**，绝不阻塞等输入。
#    用 `script` 造 pty 实测：只读 isatty 判定，不等 pty 的 EOF，实测约 0.03s 返回。
if command -v script >/dev/null 2>&1; then
  TTY_START="$(python3 -c 'import time;print(time.time())')"
  assert_eq "$(run_timed /dev/null "pty" "$WORK/ocr-tty.txt" "$WORK/ocr-tty.err" -- script -q /dev/null "$MACAI" ocr - --json)" "1" "TTY 下 ocr - 退出码 = 1（超时保护内返回，没挂住）"
  TTY_ELAPSED="$(python3 -c "import time;print('%.2f' % (time.time()-$TTY_START))")"
  TTY_FAST="$(python3 -c "print('yes' if $TTY_ELAPSED < 2 else 'no')")"
  assert_eq "$TTY_FAST" "yes" "TTY 下 ocr - 立即返回（实测 ${TTY_ELAPSED}s，阈值 2s）"
  assert_contains "$(cat "$WORK/ocr-tty.txt" "$WORK/ocr-tty.err")" "当前是终端" "TTY 下报「不是管道」而不是挂住"
else
  skip "系统没有 script（无法造 pty），跳过 TTY 断言"
fi

# ⑤ 同一张图：stdin 与文件路径必须等值（除 file 与 ms），命中数一致
if [ -f "$WORK/fixture.rtf.png" ]; then
  "$MACAI" ocr "$WORK/fixture.rtf.png" --lang en-US --json > "$WORK/ocr-path.json"
  assert_ok "$?" "路径侧 OCR 成功"
  assert_ok "$(run_timed "$WORK/fixture.rtf.png" "stdin 图片" "$WORK/ocr-stdin.json" "$WORK/ocr-stdin.err" -- "$MACAI" ocr - --lang en-US --json)" "stdin 侧 OCR 成功（真实图片字节走管道）"
  assert_json_equivalent "$WORK/ocr-path.json" "$WORK/ocr-stdin.json" "$WORK/fixture.rtf.png" "stdin 与路径：除 file/ms 外完全等值、lines 逐元素相等"
  assert_json "$(cat "$WORK/ocr-stdin.json")" "d['data']['file']=='<stdin>'" "stdin 侧如实记 file=<stdin>（不落盘、不冒充路径）"
  # 与真实二进制对照同一份基准（含 20 条已知字符串）时，两侧命中数必须一致 —— 见 docs/DEVELOPMENT.md
  if [ -x "$EXPECT_PROBE" ]; then
    FIXTURE_2560="$WORK/fixture-2560.png"
    EXPECT_2560="${FIXTURE_2560%.png}.expect.txt"   # 生成器的侧车命名是 <名字>.expect.txt（不是 .png.expect.txt）
    "$EXPECT_PROBE" ocr --render-fixture "$FIXTURE_2560" >/dev/null 2>&1 || true
    if [ -f "$FIXTURE_2560" ] && [ -f "$EXPECT_2560" ]; then
      "$MACAI" ocr "$FIXTURE_2560" --lang zh-Hans,en-US --json > "$WORK/ocr-2560-path.json"
      assert_ok "$(run_timed "$FIXTURE_2560" "2560 fixture" "$WORK/ocr-2560-stdin.json" "$WORK/ocr-2560-stdin.err" -- "$MACAI" ocr - --lang zh-Hans,en-US --json)" "2560×1440 fixture 两侧都跑通"
      assert_json_equivalent "$WORK/ocr-2560-path.json" "$WORK/ocr-2560-stdin.json" "$FIXTURE_2560" "2560×1440 fixture：stdin 与路径完全等值"
      assert_hits "$WORK/ocr-2560-path.json" "$EXPECT_2560" "18/20" "路径侧命中数 = 18/20（基准对照）"
      assert_hits "$WORK/ocr-2560-stdin.json" "$EXPECT_2560" "18/20" "stdin 侧命中数 = 18/20（与路径一致）"
    else
      skip "fixture 生成器没产出图或 .expect.txt 侧车（$EXPECT_PROBE），跳过 2560 基准对照"
    fi
  elif [ -n "$EXPECT_PROBE" ]; then
    skip "fixture 生成器不可执行（$EXPECT_PROBE），跳过 2560 基准对照"
  else
    skip "没有设置 MACAI_EXPECT_PROBE（可选外部 fixture 生成器），跳过 2560 基准对照"
  fi
else
  skip "图文 fixture 没生成，跳过 stdin/路径等值断言"
fi

# ---------------------------------------------------------------- OCR 帧流（- --frames，一次进程多图）
head2 "OCR 帧流（- --frames）"
# ① --frames 只对 stdin 有效：不带 - 是参数错（1），且 hint 必须说清楚（不依赖任何 fixture）
FRAMES_NO_DASH="$("$MACAI" ocr "$WORK/fixture.rtf.png" --frames 2>&1)"
assert_eq "$?" "1" "ocr <路径> --frames 退出码 = 1"
assert_contains "$FRAMES_NO_DASH" "--frames 只对 stdin 有效" "--frames 不带 - 时 hint 说明只对 stdin 有效"
FRAMES_MIX="$("$MACAI" ocr - "$WORK/fixture.rtf.png" --frames 2>&1)"
assert_eq "$?" "1" "ocr - <路径> --frames 退出码 = 1（不混用）"
assert_contains "$FRAMES_MIX" "不能与真实路径混用" "帧流与真实路径混用时说明原因"
FRAMES_ALONE="$("$MACAI" ocr --frames 2>&1)"
assert_eq "$?" "1" "ocr --frames（连 - 都没写）退出码 = 1"
assert_contains "$FRAMES_ALONE" "--frames 只对 stdin 有效" "ocr --frames 也提示只对 stdin 有效"
FRAMES_ORDER="$("$MACAI" ocr --frames - 2>&1 </dev/null)"
assert_eq "$?" "1" "ocr --frames -（开关在前）退出码 = 1（空流）"
assert_contains "$FRAMES_ORDER" "stdin 是空的" "--frames 在 - 之前也被当开关（不吃掉后面的 -）"
# ② 空流（EOF 立刻到来）= 参数错 1
: > "$WORK/frames-empty.bin"
assert_eq "$(run_timed "$WORK/frames-empty.bin" "空帧流" "$WORK/frames-empty.json" "$WORK/frames-empty.err" -- "$MACAI" ocr - --frames --json)" "1" "空帧流退出码 = 1（不挂住）"
assert_contains "$(cat "$WORK/frames-empty.json")" "stdin 是空的" "空帧流报「stdin 是空的」"
# ③ 帧体被截断（声明 100 只给 5）= 运行失败 2，且点名第几帧
printf '\x00\x00\x00\x64short' > "$WORK/frames-trunc.bin"
assert_eq "$(run_timed "$WORK/frames-trunc.bin" "截断帧" "$WORK/frames-trunc.json" "$WORK/frames-trunc.err" -- "$MACAI" ocr - --frames --json)" "2" "截断帧退出码 = 2"
assert_contains "$(cat "$WORK/frames-trunc.json")" "第 1 帧被截断" "截断帧点名第几帧"
# ④ 单帧声明 4 GiB（> 64 MiB 上限）= 2，且**在读字节之前**就拒（不按声明长度分配）
printf '\xff\xff\xff\xff' > "$WORK/frames-huge.bin"
assert_eq "$(run_timed "$WORK/frames-huge.bin" "单帧超限" "$WORK/frames-huge.json" "$WORK/frames-huge.err" -- "$MACAI" ocr - --frames --json)" "2" "单帧声明 4 GiB 退出码 = 2"
assert_contains "$(cat "$WORK/frames-huge.json")" "超过单帧上限" "单帧超限报明确错误"
# ⑤ 终止符之后还有字节 = 2（不允许静默忽略）
printf '\x00\x00\x00\x00x' > "$WORK/frames-trailing.bin"
assert_eq "$(run_timed "$WORK/frames-trailing.bin" "终止符后有字节" "$WORK/frames-trailing.json" "$WORK/frames-trailing.err" -- "$MACAI" ocr - --frames --json)" "2" "终止符后有字节退出码 = 2"
assert_contains "$(cat "$WORK/frames-trailing.json")" "终止符" "终止符后有字节报明确错误"

# 第二张图文 fixture（帧流等值要有两张不同内容的图才验得出顺序）
printf 'MACAI-E2E SECOND PAGE\nserial: 123456789\n' > "$WORK/fixture2.txt"
if textutil -convert rtf -output "$WORK/fixture2.rtf" "$WORK/fixture2.txt" 2>/dev/null \
   && qlmanage -t -s 900 -o "$WORK" "$WORK/fixture2.rtf" >/dev/null 2>&1 \
   && [ -f "$WORK/fixture2.rtf.png" ]; then FIXTURE2=1; else FIXTURE2=0; fi

if [ -f "$WORK/fixture.rtf.png" ] && [ "$FIXTURE2" = "1" ]; then
  # ⑥ 第 2 帧不是图片：必须点名第几帧 + 退出码 2
  python3 - "$WORK/fixture.rtf.png" "$WORK/frames-bad2.bin" <<'PY'
import struct, sys
good = open(sys.argv[1], "rb").read()
with open(sys.argv[2], "wb") as f:
    f.write(struct.pack(">I", len(good)) + good + struct.pack(">I", 5) + b"junk!" + struct.pack(">I", 0))
PY
  assert_eq "$(run_timed "$WORK/frames-bad2.bin" "第 2 帧垃圾" "$WORK/frames-bad2.json" "$WORK/frames-bad2.err" -- "$MACAI" ocr - --frames --json)" "2" "第 2 帧不是图片退出码 = 2"
  assert_contains "$(cat "$WORK/frames-bad2.json")" "第 2 帧" "非图片帧点名是第 2 帧"

  # ⑦ N 帧帧流 == N 张路径，逐元素相等（验收 5 的自动化断言）
  frames_of "$WORK/fixture.rtf.png" "$WORK/fixture2.rtf.png" > "$WORK/frames-two.bin"
  "$MACAI" ocr "$WORK/fixture.rtf.png" "$WORK/fixture2.rtf.png" --lang en-US --json > "$WORK/frames-paths.json"
  assert_ok "$?" "多路径侧 OCR 成功（2 张）"
  assert_ok "$(run_timed "$WORK/frames-two.bin" "两帧流" "$WORK/frames-two.json" "$WORK/frames-two.err" -- "$MACAI" ocr - --frames --lang en-US --json)" "帧流侧 OCR 成功（1 次进程 2 张）"
  assert_pages_equivalent "$WORK/frames-paths.json" "$WORK/frames-two.json" 2 "帧流 2 帧 == 多路径 2 张（除 file/ms 外逐元素相等）"
  assert_json "$(cat "$WORK/frames-two.json")" "d['data']['pages'][0]['file']=='<stdin>#1' and d['data']['pages'][1]['file']=='<stdin>#2'" "帧流每页如实记 <stdin>#N"
  assert_eq "$(run_timed "$WORK/frames-two.bin" "两帧流（人读）" "$WORK/frames-two.txt" "$WORK/frames-two.err2" -- "$MACAI" ocr - --frames --lang en-US)" "0" "帧流人类可读模式跑通"
  assert_contains "$(cat "$WORK/frames-two.txt")" "# <stdin>#1" "人类可读模式多帧打 # <stdin>#N 分隔行"

  # ⑧ 单帧流的输出形状与单路径一致（没有 pages 包裹）
  frames_of "$WORK/fixture.rtf.png" > "$WORK/frames-one.bin"
  assert_ok "$(run_timed "$WORK/frames-one.bin" "单帧流" "$WORK/frames-one.json" "$WORK/frames-one.err" -- "$MACAI" ocr - --frames --lang en-US --json)" "单帧流跑通"
  assert_json "$(cat "$WORK/frames-one.json")" "'pages' not in d['data'] and d['data']['file']=='<stdin>#1'" "单帧流输出形状 = 单页（与 macai ocr a.png 一致）"
  assert_json "$(cat "$WORK/frames-one.json")" "d['data']['line_count']>=2" "单帧流识别出已知文字的行"
else
  skip "图文 fixture 不足两张，跳过帧流等值断言"
fi

# ---------------------------------------------------------------- OCR 帧流性能（8 × 2560×1440，验收 7）
head2 "OCR 帧流性能（8 张 2560×1440）"
if [ -x "$EXPECT_PROBE" ]; then
  BENCH_DIR="$WORK/bench"
  mkdir -p "$BENCH_DIR"
  "$EXPECT_PROBE" ocr --render-fixture "$BENCH_DIR/base.png" >/dev/null 2>&1 || true
  if [ -f "$BENCH_DIR/base.png" ]; then
    for i in 1 2 3 4 5 6 7 8; do cp "$BENCH_DIR/base.png" "$BENCH_DIR/f$i.png"; done
    # 逐次调用 = 8 次进程；--frames = 1 次进程。各 3 轮取中位数，并顺带断言两侧结果等值。
    BENCH="$(python3 - "$MACAI" "$BENCH_DIR" "$WORK/frames-8.bin" <<'PY'
import json, statistics, struct, subprocess, sys, time
macai, bench, stream_path = sys.argv[1], sys.argv[2], sys.argv[3]
imgs = ["%s/f%d.png" % (bench, i) for i in range(1, 9)]
blobs = [open(p, "rb").read() for p in imgs]
with open(stream_path, "wb") as f:
    f.write(b"".join(struct.pack(">I", len(b)) + b for b in blobs) + struct.pack(">I", 0))
args = ["--lang", "zh-Hans,en-US", "--json"]
def run(cmd, stdin_path=None):
    with open(stdin_path or "/dev/null", "rb") as handle:
        return subprocess.run(cmd, stdin=handle, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
seq_times, frame_times, seq_outs = [], [], None
for _ in range(3):
    start = time.monotonic()
    outs = [run([macai, "ocr", p] + args).stdout for p in imgs]
    seq_times.append(time.monotonic() - start)
    seq_outs = outs
    start = time.monotonic()
    run([macai, "ocr", "-", "--frames"] + args, stream_path)
    frame_times.append(time.monotonic() - start)
frame_out = run([macai, "ocr", "-", "--frames"] + args, stream_path).stdout
seq_pages = [json.loads(o)["data"] for o in seq_outs]
frames_pages = json.loads(frame_out)["data"]["pages"]
def strip(page):
    page = dict(page); page.pop("ms", None); page.pop("file", None); return page
equivalent = [strip(p) for p in seq_pages] == [strip(p) for p in frames_pages] \
    and [p["lines"] for p in seq_pages] == [p["lines"] for p in frames_pages]
seq_med = statistics.median(seq_times)
frame_med = statistics.median(frame_times)
print("SEQ=%.3f" % seq_med)
print("FRAMES=%.3f" % frame_med)
print("SPEEDUP=%.2f" % (seq_med / frame_med))
print("EQUIV=%s" % ("TRUE" if equivalent else "FALSE"))
PY
)"
    printf '  ℹ️ %s\n' "$(printf '%s' "$BENCH" | tr '\n' ' ')"
    assert_eq "$(printf '%s' "$BENCH" | awk -F= '/^EQUIV=/{print $2}')" "TRUE" "8 张 2560×1440：帧流结果与逐次调用逐元素等值"
    assert_eq "$(printf '%s' "$BENCH" | awk -F= '/^SPEEDUP=/{print ($2 >= 1.2) ? "yes" : "no"}')" "yes" "8 张 2560×1440：1 次 --frames 明显快于 8 次进程（中位数 ≥ 1.2×）"
  else
    skip "fixture 生成器没产出 2560×1440 图，跳过帧流性能实测"
  fi
else
  skip "没有设置 MACAI_EXPECT_PROBE（可选外部 fixture 生成器），跳过帧流性能实测"
fi

# ---------------------------------------------------------------- TTS
head2 "TTS"
TTS_OUT="$WORK/speech.wav"
TTS_TEXT="这是端到端验收用的语音，编号九八七六五四。"
TTS_JSON="$("$MACAI" tts --text "$TTS_TEXT" --lang zh-CN --out "$TTS_OUT" --json)"
assert_json "$TTS_JSON" "d['ok'] and d['data']['bytes']>4000" "合成出非空音频"
assert_json "$TTS_JSON" "d['data']['duration_seconds']>0.5" "音频时长合理"
if [ -f "$TTS_OUT" ]; then ok "文件确实落在 --out 指定路径"; else bad "文件没落在 --out 指定路径"; fi

# 输出路径是用户数据边界：已存在文件/目录必须拒绝，且原内容一点不能动。
EXISTING_FILE="$WORK/existing.wav"
printf 'keep-me' > "$EXISTING_FILE"
"$MACAI" tts --text "hello" --out "$EXISTING_FILE" --json >/dev/null 2>&1
assert_eq "$?" "1" "已存在文件：tts 拒绝覆盖（退出码 1）"
assert_eq "$(cat "$EXISTING_FILE")" "keep-me" "已存在文件：被拒绝后原内容未变"
EXISTING_DIR="$WORK/existing-dir"
mkdir -p "$EXISTING_DIR"
printf 'still-here' > "$EXISTING_DIR/keep.txt"
"$MACAI" tts --text "hello" --out "$EXISTING_DIR" --json >/dev/null 2>&1
assert_eq "$?" "1" "目录作为 --out：tts 拒绝写入（退出码 1）"
if [ -d "$EXISTING_DIR" ] && [ -f "$EXISTING_DIR/keep.txt" ]; then
  ok "目录作为 --out：原目录与文件仍在"
else
  bad "目录作为 --out：目录内容被破坏"
fi
VOICES="$("$MACAI" voices --lang zh --json)"
assert_json "$VOICES" "d['data']['count']>0" "中文音色可用"

# ---------------------------------------------------------------- STT（闭环：自己合成的音频再转写回来）
head2 "STT"
STT_STATUS="$("$MACAI" stt --status --locale zh-CN --json)"
assert_json "$STT_STATUS" "d['ok']" "资产状态可查询"
if printf '%s' "$STT_STATUS" | grep -q '"installed" : true'; then
  STT_TEXT="$("$MACAI" stt "$TTS_OUT" --locale zh-CN)"
  assert_contains "$STT_TEXT" "语音" "闭环转写命中关键词"
  STT_SRT="$("$MACAI" stt "$TTS_OUT" --locale zh-CN --format srt)"
  assert_contains "$STT_SRT" "-->" "SRT 有时间轴"
  STT_JSON="$("$MACAI" stt "$TTS_OUT" --locale zh-CN --json)"
  assert_json "$STT_JSON" "d['data']['segment_count']>=1 and d['data']['raw_text']!=d['data']['text'] or d['data']['text']!=''" "JSON 含分段与规范化文本"
  # MCP 的 format 参数必须真的生效，而不是只写在 schema 里。
  MCP_STT_SRT="$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"macai_transcribe\",\"arguments\":{\"path\":\"$TTS_OUT\",\"locale\":\"zh-CN\",\"format\":\"srt\"}}}" \
    | "$MACAI" mcp)"
  assert_jsonl "$MCP_STT_SRT" "any(m.get('id')==2 and '-->' in m.get('result',{}).get('content',[{}])[0].get('text','') for m in d)" "MCP transcribe format=srt 返回时间轴"
else
  skip "zh-CN 语音资产未安装（跑 macai stt --install-assets --locale zh-CN 修复）"
fi
assert_eq "$("$MACAI" stt --locales --json | python3 -c 'import json,sys;print("TRUE" if json.load(sys.stdin)["data"]["count"]>0 else "FALSE")')" "TRUE" "支持语言列表非空"

# ---------------------------------------------------------------- NLP
head2 "NLP"
NLP_JSON="$("$MACAI" nlp --text "Tim Cook works at Apple Inc. in Cupertino." --json)"
assert_json "$NLP_JSON" "d['data']['language'].startswith('en')" "语种识别"
assert_json "$NLP_JSON" "d['data']['token_count']>=5" "分词"
assert_json "$NLP_JSON" "any('PersonalName' in e for e in d['data']['entities'])" "命名实体"
assert_json "$NLP_JSON" "len(d['data']['sentences'])>=1" "句子切分"

# ---------------------------------------------------------------- 声音分析
head2 "声音分析"
if [ -f "$TTS_OUT" ]; then
  SOUND_JSON="$("$MACAI" sound "$TTS_OUT" --top 3 --json)"
  assert_json "$SOUND_JSON" "d['data']['window_count']>0" "有分类窗口"
  assert_json "$SOUND_JSON" "any(x['confidence']>0.2 for x in d['data']['top_labels'])" "置信度非零"
  SOUND_BAD="$("$MACAI" sound "$TTS_OUT" --top -1 --json 2>/dev/null)"; SOUND_BAD_RC=$?
  assert_eq "$SOUND_BAD_RC" "1" "负 top 返回参数错误而不是崩溃"
  assert_json "$SOUND_BAD" "d['ok'] is False and d['code']==1 and 'top' in d['message']" "负 top 走统一错误信封"
fi

# ---------------------------------------------------------------- 翻译
head2 "翻译"
TR_STATUS="$("$MACAI" translate --status --from en --to zh-Hans --json)"
assert_json "$TR_STATUS" "d['ok'] and len(d['data']['pairs'])==1" "语言包状态可查询"
if printf '%s' "$TR_STATUS" | grep -q '"state" : "installed"'; then
  TR_TEXT="$("$MACAI" translate --from en --to zh-Hans --text "The system works offline.")"
  if [ -n "$TR_TEXT" ]; then ok "离线翻译返回内容: $TR_TEXT"; else bad "离线翻译返回空"; fi
else
  skip "en→zh-Hans 语言包未安装（在「翻译」App 里选一次该语言对即可）"
fi

# ---------------------------------------------------------------- MCP
head2 "MCP（stdio）"
MCP_OUT="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"macai_nlp","arguments":{"text":"Hello world from MCP."}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"macai_ocr","arguments":{"path":"/nonexistent.png"}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"macai_sound","arguments":{"path":"/nonexistent.wav","top":-1}}}' \
  | "$MACAI" mcp)"
assert_jsonl "$MCP_OUT" "any(m.get('id')==1 and m.get('result',{}).get('serverInfo',{}).get('name')=='macai' for m in d)" "initialize 报出 serverInfo"
assert_jsonl "$MCP_OUT" "any(m.get('id')==2 and len(m.get('result',{}).get('tools',[]))>=6 for m in d)" "tools/list 暴露 ≥6 个工具"
assert_contains "$MCP_OUT" "macai_ocr" "tools/list 暴露 OCR 工具"
assert_contains "$MCP_OUT" "macai_transcribe" "tools/list 暴露转写工具"
assert_jsonl "$MCP_OUT" "any(m.get('id')==3 and 'Hello world from MCP.' in json.dumps(m) for m in d)" "tools/call 真的跑通了 NLP"
assert_jsonl "$MCP_OUT" "any(m.get('id')==4 and m.get('result',{}).get('isError') is True for m in d)" "工具报错以 isError 返回而不是崩掉服务器"
assert_jsonl "$MCP_OUT" "any(m.get('id')==5 and m.get('result',{}).get('isError') is True and 'top' in json.dumps(m) for m in d)" "负 top 的 MCP 调用以 isError 返回（不断连）"

# --- 协议版本协商（规范 lifecycle：支持才回请求值，不支持 MUST 回服务器支持的版本，绝不回显）
# 每次握手单开一条连接：initialize 是连接级协商，塞进同一条流里会读到前一次的结果。
mcp_handshake() { # <请求的 protocolVersion> → stdout 里那一行 initialize 结果
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"$1\",\"capabilities\":{},\"clientInfo\":{\"name\":\"e2e\",\"version\":\"1\"}}}" \
    | "$MACAI" mcp
}
assert_json "$(mcp_handshake 2024-11-05)" \
  "d['result']['protocolVersion']=='2024-11-05'" "请求 2024-11-05 → 原样回 2024-11-05"
assert_json "$(mcp_handshake 2025-06-18)" \
  "d['result']['protocolVersion']=='2025-06-18'" "请求 2025-06-18 → 原样回 2025-06-18"
assert_json "$(mcp_handshake 1999-01-01)" \
  "d['result']['protocolVersion']=='2025-06-18'" "未知版本 → 回 supported 列表里最新的，而不是回显 1999-01-01"
assert_json "$(mcp_handshake 2025-11-25)" \
  "d['result']['protocolVersion'] in ('2025-06-18','2024-11-05')" "未实现的 2025-11-25 → 回支持列表里的版本（不谎报）"
# 谎报的具体形态就是这么来的：客户端要 2025-11-25，服务器回 2025-11-25，随后调 resources/* 落到 -32601。
assert_json "$(mcp_handshake 2025-11-25)" \
  "d['result']['protocolVersion']!='2025-11-25'" "协议版本不回声（防「声称支持却没实现」的静默失败）"

# --- 工具元数据：title 与 annotations 是客户端（Anthropic 目录审核 / GUI 确认框）真实消费的字段
TOOLS_LIST="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | "$MACAI" mcp)"
assert_jsonl "$TOOLS_LIST" "all(isinstance(t.get('title'),str) and t['title'] for t in d[1]['result']['tools'])" "每个工具都有非空 title"
assert_jsonl "$TOOLS_LIST" \
  "all(t['annotations']['readOnlyHint'] is True and t['annotations']['openWorldHint'] is False for t in d[1]['result']['tools'] if t['name']!='macai_speak')" \
  "只读工具声明 readOnlyHint / openWorldHint"
assert_jsonl "$TOOLS_LIST" \
  "all(t['annotations']['readOnlyHint'] is False and t['annotations']['destructiveHint'] is False and t['annotations']['idempotentHint'] is False and t['annotations']['openWorldHint'] is False for t in d[1]['result']['tools'] if t['name']=='macai_speak')" \
  "macai_speak 声明为非只读、增量写（不覆盖既有内容）"
# 规范默认值是悲观值（非只读 / 可能破坏 / 开放世界）：漏声明就等于让客户端按最坏情况处理。
assert_jsonl "$TOOLS_LIST" "all('annotations' in t for t in d[1]['result']['tools'])" "没有任何工具漏声明 annotations"

# --- server instructions（initialize 结果的顶格字段）
# 上限不是凭感觉：Claude Code 在 4096 字符处截断，dsh 的上限是 32768 字节且超了直接抛错断连。
assert_jsonl "$TOOLS_LIST" \
  "isinstance(d[0]['result'].get('instructions'),str) and 0 < len(d[0]['result']['instructions']) < 4096" \
  "initialize 带 instructions 且长度 < 4096 字符"
assert_jsonl "$TOOLS_LIST" \
  "len(d[0]['result']['instructions'].encode('utf-8')) < 2048" "instructions 的 UTF-8 字节数 < 2 KB"
# 目录审核把工具描述/instructions 里的祈使指令判为 prompt injection —— 这里只陈述事实与约束。
assert_jsonl "$TOOLS_LIST" \
  "not any(p in d[0]['result']['instructions'] for p in ('你必须','请务必','必须先','一定要先'))" \
  "instructions 不含祈使式强制指令（避免被判 prompt injection）"
assert_jsonl "$TOOLS_LIST" \
  "all(k in d[0]['result']['instructions'] for k in ('离线','locale','capabilities','en-US'))" \
  "instructions 覆盖离线/语言/capabilities/中英混说四件事"

# --- 失败信封：与 CLI 统一成 {ok, code, message, retryable, remediation}（error/hint 保留为别名）
MCP_ERRORS="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"macai_ocr","arguments":{"path":"/nonexistent.png"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"macai_transcribe","arguments":{"path":"/nonexistent.wav","locale":"tlh"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"macai_ocr","arguments":{}}}' \
  | "$MACAI" mcp)"
# 信封字段逐个断言（用 json.dumps 复原 content 里的那段 JSON 文本）
assert_jsonl "$MCP_ERRORS" \
  "all(set(json.loads(m['result']['content'][0]['text'])) >= {'ok','code','message','retryable'} for m in d if m.get('id') in (2,3,4))" \
  "错误信封带 ok / code / message / retryable"
assert_jsonl "$MCP_ERRORS" \
  "all(json.loads(m['result']['content'][0]['text'])['ok'] is False and m['result']['isError'] is True for m in d if m.get('id') in (2,3,4))" \
  "isError 保持为 true（旧客户端依赖它）"
# 运行失败（文件不存在，退出码 2）→ 可重试
assert_jsonl "$MCP_ERRORS" \
  "json.loads(d[1]['result']['content'][0]['text'])['code']==2 and json.loads(d[1]['result']['content'][0]['text'])['retryable'] is True" \
  "运行失败（2）→ retryable=true"
# 能力不可用（语言不支持，退出码 3）→ 不可重试，且带 remediation 指路
assert_jsonl "$MCP_ERRORS" \
  "json.loads(d[2]['result']['content'][0]['text'])['code']==3 and json.loads(d[2]['result']['content'][0]['text'])['retryable'] is False and json.loads(d[2]['result']['content'][0]['text'])['remediation']" \
  "能力不可用（3）→ retryable=false 且 remediation 给出路"
# 参数错（退出码 1）→ 不可重试
assert_jsonl "$MCP_ERRORS" \
  "json.loads(d[3]['result']['content'][0]['text'])['code']==1 and json.loads(d[3]['result']['content'][0]['text'])['retryable'] is False" \
  "参数错（1）→ retryable=false"
# 向后兼容：error / hint 仍在（CLI 侧自 0.1.0 起就有的字段名）
assert_jsonl "$MCP_ERRORS" \
  "all('error' in json.loads(m['result']['content'][0]['text']) for m in d if m.get('id') in (2,3,4))" \
  "error 字段保留（兼容别名）"

# ---------------------------------------------------------------- 汇总
printf '\n——————————————————————————————\n'
printf '通过 %d / 失败 %d / 跳过 %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
