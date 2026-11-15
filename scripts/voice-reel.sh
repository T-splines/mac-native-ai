#!/usr/bin/env bash
# 生成「音色试听」与「音调对比」两条音频，方便挑声音（光看名字选不出来）。
#
#   scripts/voice-reel.sh               # 中文全部音色试听 + 婷婷音调对比，输出到 bin/
#   scripts/voice-reel.sh --lang en     # 换语言
#
# 依赖 ffmpeg（拼接与响度统一）。没有 ffmpeg 时会退化成"只留每个音色的单独文件"。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACAI="${MACAI:-$ROOT/bin/macai}"
[ -x "$MACAI" ] || MACAI="$ROOT/.build/debug/macai"
[ -x "$MACAI" ] || { echo "先跑 scripts/build.sh" >&2; exit 1; }

LANG_PREFIX="zh"
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) LANG_PREFIX="${2:-zh}"; shift 2 ;;
    *) echo "未知参数 $1" >&2; exit 1 ;;
  esac
done

WORK="$(mktemp -d -t macai-voice-reel)"
mkdir -p "$ROOT/bin"
OUT="$ROOT/bin/voice-reel-${LANG_PREFIX}"

echo "==> 为每个音色合成试听句（${LANG_PREFIX}）"
"$MACAI" voices --lang "$LANG_PREFIX" --sample --out-dir "$WORK/voices" \
  --text "你好呀，我是{name}，很高兴认识你。" | tee "$WORK/voices.txt"

FFMPEG=""
for candidate in "$(command -v ffmpeg || true)" "$HOME/.local/bin/ffmpeg" /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then FFMPEG="$candidate"; break; fi
done

if [ -z "$FFMPEG" ]; then
  echo "⚠️ 没找到 ffmpeg：每个音色的样音在 $WORK/voices/（不拼成一条，也不转 mp3）"
  echo "   目录: $WORK/voices"
  exit 0
fi

echo "==> 拼接成一条（音色之间 0.45s 静音，响度统一到 -18 LUFS）"
python3 - "$FFMPEG" "$WORK" "$OUT" "$LANG_PREFIX" <<'PY'
import subprocess, sys, os, glob
ff, work, out, lang = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
files = sorted(glob.glob(os.path.join(work, "voices", "*.wav")))
gap = os.path.join(work, "_gap.wav")
subprocess.run([ff, "-y", "-f", "lavfi", "-i", "anullsrc=r=22050:cl=mono", "-t", "0.45",
                "-c:a", "pcm_s16le", gap], capture_output=True)
lst = os.path.join(work, "list.txt")
with open(lst, "w") as fh:
    for f in files[:-1]:
        fh.write("file '%s'\nfile '%s'\n" % (f, gap))
    if files:
        fh.write("file '%s'\n" % files[-1])
wav = out + ".wav"
subprocess.run([ff, "-y", "-f", "concat", "-safe", "0", "-i", lst,
                "-af", "loudnorm=I=-18:TP=-2:LRA=11", "-ar", "22050", "-ac", "1",
                "-c:a", "pcm_s16le", wav], capture_output=True)
mp3 = out + ".mp3"
subprocess.run([ff, "-y", "-i", wav, "-codec:a", "libmp3lame", "-b:a", "64k", "-ac", "1", mp3],
               capture_output=True)
print("   音色数:", len(files))
print("   输出:", mp3, os.path.getsize(mp3), "字节")
PY

# 音调对比：同一个音色在几档音调下的差别（"更年轻/更甜"通常靠 pitch + 稍慢语速）
VOICE_DEFAULT="$("$MACAI" voices --lang "$LANG_PREFIX" --gender female --json \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['data']['voices']; print(d[0]['name'] if d else '')" 2>/dev/null || true)"
if [ -n "$VOICE_DEFAULT" ]; then
  echo "==> 音调对比（音色 ${VOICE_DEFAULT}：默认 / 1.15 / 1.3 / 1.5+慢）"
  mkdir -p "$WORK/pitch"
  "$MACAI" tts --voice "$VOICE_DEFAULT" --text "这是默认音调，你好呀。" --out "$WORK/pitch/1.wav" >/dev/null
  "$MACAI" tts --voice "$VOICE_DEFAULT" --pitch 1.15 --text "这是音调一点一五，你好呀。" --out "$WORK/pitch/2.wav" >/dev/null
  "$MACAI" tts --voice "$VOICE_DEFAULT" --pitch 1.3 --text "这是音调一点三，你好呀。" --out "$WORK/pitch/3.wav" >/dev/null
  "$MACAI" tts --voice "$VOICE_DEFAULT" --pitch 1.5 --rate 0.46 --text "这是音调一点五，语速稍慢，你好呀。" --out "$WORK/pitch/4.wav" >/dev/null
  python3 - "$FFMPEG" "$WORK" "$ROOT/bin/voice-pitch-reel" <<'PY'
import subprocess, sys, os
ff, work, out = sys.argv[1], sys.argv[2], sys.argv[3]
files = [os.path.join(work, "pitch", f"{i}.wav") for i in (1, 2, 3, 4)]
gap = os.path.join(work, "pitch_gap.wav")
subprocess.run([ff, "-y", "-f", "lavfi", "-i", "anullsrc=r=22050:cl=mono", "-t", "0.5",
                "-c:a", "pcm_s16le", gap], capture_output=True)
lst = os.path.join(work, "pitch.txt")
with open(lst, "w") as fh:
    for f in files[:-1]:
        fh.write("file '%s'\nfile '%s'\n" % (f, gap))
    fh.write("file '%s'\n" % files[-1])
wav = out + ".wav"
subprocess.run([ff, "-y", "-f", "concat", "-safe", "0", "-i", lst, "-af", "loudnorm=I=-18:TP=-2:LRA=11",
                "-ar", "22050", "-ac", "1", "-c:a", "pcm_s16le", wav], capture_output=True)
subprocess.run([ff, "-y", "-i", wav, "-codec:a", "libmp3lame", "-b:a", "64k", "-ac", "1", out + ".mp3"],
               capture_output=True)
print("   输出:", out + ".mp3", os.path.getsize(out + ".mp3"), "字节")
PY
fi

echo ""
echo "完成。把 mp3 发出去让对方挑；要固定音色/音调，直接改本脚本里的 --sample 文本或调用参数。"
echo "临时目录（每个音色的单独样音）: $WORK"
