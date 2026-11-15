# macai — macOS built-in AI in one offline binary

**Your Mac already ships six AI capabilities. `macai` gives them a single CLI and an MCP server — zero third-party dependencies, zero API keys, zero per-call fees.**

macOS hides OCR, speech recognition, speech synthesis, text analysis, sound classification
and offline translation inside system frameworks. Scripts and agents cannot reach them
easily. `macai` wraps all six in **one Swift binary**:

- **one binary, two shapes** — `macai <command>` for the shell, `macai mcp` for MCP hosts;
- **offline inference** — Vision / Speech / AVFoundation / NaturalLanguage / SoundAnalysis /
  Translation run in-process; no telemetry, no API key. The only network action is macOS's
  one-time speech-asset download, and only when you ask for it with `--install-assets`;
- **honest failures** — a stable JSON envelope, stable exit codes, and an actionable
  `remediation` instead of an empty result;
- **built for agents** — MCP tools carry `title` and `annotations`; the server negotiates
  protocol versions and ships compact instructions.

- [What it does](#what-it-does)
- [Why this exists](#why-this-exists)
- [Install](#install)
- [Use it from an MCP client](#use-it-from-an-mcp-client)
- [First verification](#first-verification)
- [MCP tools](#mcp-tools)
- [CLI](#cli)
- [Privacy and security boundary](#privacy-and-security-boundary)
- [How it compares](#how-it-compares)
- [Known limitations](#known-limitations)
- [Development and tests](#development-and-tests)

## What it does

| capability | system framework | what you get |
|:--|:--|:--|
| OCR | Vision `VNRecognizeTextRequest` | lines of text with confidence and pixel bounding boxes; optional barcodes; up to 30 languages |
| speech-to-text | Speech `SpeechTranscriber` / `SpeechAnalyzer` (macOS 26) | offline transcription with `locale`, `txt/json/srt` output |
| text-to-speech | AVFoundation `AVSpeechSynthesizer` | audio files from system voices; rate/pitch controls |
| text analysis | NaturalLanguage | language, tokenization, part of speech, named entities, sentence splitting |
| sound classification | SoundAnalysis | about 300 categories (speech, laughter, music, alarms, …) |
| translation | Translation | offline text translation when the language pair is installed |

The binary also exposes **capabilities** (which voices/assets/language packs are ready on this
machine) and **selftest** (an end-to-end pass over the six capabilities).

## Why this exists

Cloud OCR and speech APIs are excellent, but they cost money, need network access and ship
your data off-device. Multimodal LLMs can read images, but paying tokens for "what text is in
this screenshot" is wasteful. macOS already has the models — they are just locked inside
Swift frameworks with no CLI or MCP face.

`macai` is the missing adapter:

- no Python or Node runtime, no package manager, no daemon, no HTTP server in the binary;
- the system owns the models; no third-party model downloads. macOS may fetch its own speech
  assets once, only when you run `macai stt --install-assets` (or `selftest --install-assets`);
- outputs a JSON envelope designed for scripts and agents, not a human-oriented paragraph;
- reports "capability unavailable" with the exact fix command instead of pretending the
  result was empty.

## Install

Requirements: **macOS 26+** (speech recognition uses `SpeechTranscriber` / `SpeechAnalyzer`)
and the Swift toolchain from Command Line Tools.

```bash
git clone https://github.com/T-splines/mac-native-ai.git
cd mac-native-ai
./scripts/build.sh      # swift build -c release -> bin/macai
./scripts/install.sh    # symlink to ~/.local/bin/macai
export PATH="$HOME/.local/bin:$PATH"   # if ~/.local/bin is not already on PATH
macai selftest          # six-capability end-to-end self-check (no download by default)
```

`selftest` is offline unless you pass `--install-assets`. On a machine without speech
assets it reports STT as an environmental SKIP with the exact install command; translation
packs have no download API and are triggered in the Translate app / System Settings.

`build.sh` also ad-hoc signs the binary; an unsigned or partially signed binary is killed by
`taskgated` on macOS. No TCC prompt is expected: STT reads audio files and does not open the
microphone.

## Use it from an MCP client

Once `macai` is on `PATH`, add it to any MCP client:

```json
{
  "mcpServers": {
    "macai": {
      "command": "macai",
      "args": ["mcp"]
    }
  }
}
```

- **Claude Code**: `claude mcp add macai -- macai mcp`
- **Claude Desktop**: put the JSON above in `claude_desktop_config.json`
- **Any stdio MCP client**: command `macai`, argument `mcp`

GUI clients often have a minimal `PATH`; use the absolute path
`$HOME/.local/bin/macai` if `macai` is not found.

The server is a stdio child process. It does not listen on a port, does not accept remote
connections and inherits the host's permissions.

## First verification

After installing, send one sentence from your host:

> Use macai to read the text in this screenshot: `~/Desktop/shot.png`

Expected: the model calls `macai_ocr` with an absolute path and a language such as
`zh-Hans,en-US`; 100–500 ms later it returns line-by-line text with confidence and pixel
boxes. No network request is made and no model tokens are spent on OCR.

Then verify readiness:

> Use macai to show what this machine can do

Expected: `macai_capabilities` returns the TTS voice count, STT asset status, installed
translation pairs and OCR language count. If STT shows "not installed", run
`macai stt --install-assets --locale zh-CN` once.

## MCP tools

| tool | title (as returned) | what it does | read-only |
|:--|:--|:--|:--|
| `macai_ocr` | 图片文字识别 | image → lines + confidence + pixel bbox; optional barcodes | yes |
| `macai_transcribe` | 音频转文字 | audio → text (offline; `locale` selects one language; `txt/json/srt`) | yes |
| `macai_speak` | 语音合成落盘 | text → a new audio file; refuses to overwrite an existing file or directory | no |
| `macai_voices` | 可用音色列表 | system voices, filterable by language | yes |
| `macai_translate` | 离线翻译 | text → target language (requires the system language pair) | yes |
| `macai_nlp` | 文本分析 | language / tokens / POS / entities / sentences | yes |
| `macai_sound` | 声音分类 | audio → sound categories (about 300 classes) | yes |
| `macai_capabilities` | 本机能力状态 | voices, STT assets, translation packs, OCR languages | yes |

All tools except `macai_speak` declare
`annotations: {readOnlyHint: true, openWorldHint: false}`. `macai_speak` declares
`{readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false}`.
The MCP defaults are pessimistic; declaring them lets hosts auto-run the seven read-only
tools without a confirmation prompt.

The server advertises protocol versions `2025-06-18` and `2024-11-05`; an unsupported
request gets the newest supported version, never a false echo. On `initialize` it sends a
compact Chinese instruction block (under 2 KB) explaining tool selection and the three hard
constraints.

## CLI

```bash
macai ocr screenshot.png                      # text + confidence + pixel bbox
macai ocr - --frames < frames.bin             # recognize N images in one process
macai stt voice.wav --locale zh-CN            # audio -> text, fully offline
macai tts --text "three o'clock" --out out.wav
macai translate --to zh-Hans --text "offline"
macai nlp "Tim Cook works at Apple Inc."      # language / tokens / POS / entities / sentences
macai sound clip.wav --top 3                  # speech / laughter / music / alarm ...
macai mcp                                     # MCP stdio server (8 tools)
macai selftest                                # six-capability end-to-end check
macai help
```

Every command supports `--json` (`{"ok":true,"data":…}`) and stable exit codes:

| exit | meaning |
|:--|:--|
| `0` | success |
| `1` | argument / usage error |
| `2` | runtime failure |
| `3` | capability unavailable (speech assets or translation pack not installed) |

Failures use one envelope:

```json
{"ok": false, "code": 3, "message": "…", "retryable": false, "remediation": "…how to fix…"}
```

`retryable` is `false` for argument errors and unavailable capabilities, `true` for most
runtime failures. The MCP side returns the same envelope in `content[0].text` with
`isError: true`.

### Batch OCR over stdin

For window-tiled OCR, starting a process per image pays Vision initialization repeatedly.
`macai ocr -` reads one image from stdin; `macai ocr - --frames` reads a length-prefixed
stream:

```
{ [u32 big-endian length][image bytes] } … [u32 big-endian 0]
```

- length must be > 0; `0` is the terminator; EOF is also accepted;
- after the terminator no bytes may follow;
- limits: 64 MiB per frame, 64 frames, 256 MiB total; lengths are validated **before**
  allocation;
- output is element-for-element identical to passing the paths.

On an Apple Silicon Mac running macOS 26, 8 × 2560×1440 images took 3.15 s as eight
processes vs 2.22 s as one process (about 1.4×); the gain comes from one Vision initialization
per process, not from faster OCR per image.

## Privacy and security boundary

- **Data never leaves the machine.** All six capabilities are in-process system framework
  calls. Recognition and translation do not upload content. The only network action in the
  project is macOS's one-time speech-asset download, and it runs only for
  `macai stt --install-assets` / `macai selftest --install-assets`. No telemetry, no API
  keys, no accounts.
- **No credentials.** The repository has no key-reading path; `.env`, certificates and
  private keys are covered by `.gitignore` plus a pre-commit privacy scan.
- **One user-controlled write path.** `macai_speak` / `macai tts` writes a new audio file
  and refuses to overwrite an existing file or replace a directory. The other seven MCP
  tools only read inputs and return results.
- **It recognizes, it does not understand.** No image semantics, no image generation, no
  document reasoning. "What text is in this image" is in scope; "what does this image mean"
  is not.
- **Unavailable means unavailable.** Missing speech assets or translation packs return
  `code: 3` with a remediation command, not an empty string. Language packs can only be
  triggered manually in System Settings / the Translate app; the project never downloads
  them silently.

## How it compares

| | cloud API | multimodal LLM | **macai** |
|:--|:--|:--|:--|
| cost | per request | per token | **0** |
| network | required | required | **not required** |
| privacy | data leaves the device | data leaves the device | **stays local** |
| latency | network round trip | seconds | **milliseconds** (OCR ~83–472 ms) |
| semantic understanding | — | yes | **no** (recognition/conversion only) |

The point is not to replace reasoning models. It is to stop paying tokens for tasks the
operating system already does well.

## Known limitations

1. **STT handles one language at a time.** The system speech model loads per locale; mixed
   Chinese/English speech can drop Latin words (e.g. "这台 Mac" → "这台"). Run with
   `--locale en-US` when the material is English.
2. **STT assets are a one-time download.** The first use of a language needs the system
   speech assets (tens of MB, downloaded once by macOS). `macai selftest` does **not**
   download them unless you pass `--install-assets`. After installation it is fully offline.
   Missing assets fail loudly with the install command.
3. **Translation packs have no download API.** They must be triggered once in the Translate
   app / System Settings. Missing pairs return exit code 3 with instructions.
4. **No automatic language detection for STT.** Audio carries no language tag; the default
   `zh-CN` is a convenience, not a universal default.
5. **TTS container conversion uses `afconvert`.** Supported output containers are
   `wav/aiff/m4a/caf`; MP3 is not supported — convert externally if you need it. The default
   format is WAV.
6. **Vision confidence is always 0.5.** This is system behavior; do not use it as a quality
   threshold.
7. **Batch OCR memory behavior is not fully characterized.** Large images are downsampled
   for a single call, but long-running batches are still an open measurement.
8. **`--frames` is serial.** It saves process startup and Vision initialization, not per-image
   OCR time; it does not mix with real paths in the same command.
9. **macOS 26+ is a hard requirement** because the STT path uses `SpeechTranscriber` /
   `SpeechAnalyzer`.
10. **No image understanding or generation.** Use a multimodal model for semantics.

## Development and tests

```bash
./scripts/test.sh          # build + spec + selftest + e2e
swift build && ./.build/debug/macai-spec    # 145 spec assertions
./tests/e2e.sh                              # 99 assertions (environmental skips vary)
macai selftest                              # 6 capability checks
```

The full test count and protocol contract are documented in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Environmental skips depend on the machine:
missing speech assets, missing translation packs, and optional fixture generators all skip
with the exact remediation command instead of failing. Skips never hide a failure.

## License

MIT. See [LICENSE](LICENSE). The license covers this repository's source. At runtime `macai`
uses Apple's system frameworks and macOS 26+, which are not distributed here; users need a
macOS device and OS version that satisfy Apple's terms.
