# Development guide

This document is for people changing the code. User-facing documentation lives in
[README.md](README.md) / [README.zh-CN.md](README.zh-CN.md).

## Repository layout

```
Package.swift              SwiftPM manifest (macOS 26+, three targets)
Sources/MacAIKit/          library: capability wrappers, CLI plumbing, MCP server
Sources/macai/             the `macai` executable
Sources/macai-spec/        the test runner (no XCTest dependency)
tests/e2e.sh               end-to-end assertions against the real binary
scripts/                   build / install / test / privacy gate / voice demo
.githooks/pre-commit       staged privacy scan
```

The binary name is `macai`; the repository is `mac-native-ai`.

## Build and test

```bash
swift build                       # debug
./scripts/build.sh                # release + ad-hoc sign -> bin/macai
./scripts/test.sh                 # build + spec + selftest + e2e
swift build && ./.build/debug/macai-spec
./tests/e2e.sh
macai selftest
```

Expected counts: **145** spec assertions, **99** e2e assertions with environmental skips that
depend on the machine (missing speech assets, missing translation pack, optional fixture
generator), and **6** capability checks in `selftest`.

The unit runner is a plain executable (`macai-spec`) rather than XCTest or swift-testing:
a machine with only Command Line Tools has no XCTest module, and `Testing.framework` is not
on the default search path. Keeping the runner self-contained preserves the "no manual
setup" property.

## Design rules

1. **No third-party dependencies.** The package must build with `swift build` on a fresh
   Command Line Tools install. No SPM dependencies, no bundled models, no Python/Node.
2. **System frameworks only.** OCR → Vision, STT → Speech, TTS → AVFoundation, NLP →
   NaturalLanguage, sound → SoundAnalysis, translation → Translation.
3. **No network code in the binary.** No telemetry, no HTTP client. The only network steps
   are macOS-managed one-time speech-asset downloads, triggered only by
   `macai stt --install-assets` / `macai selftest --install-assets`; translation packs have
   no download API.
4. **Honest errors.** Every failure goes through one envelope
   (`ok/code/message/retryable/remediation` plus `error`/`hint` aliases), with exit codes
   `0/1/2/3`. Never return an empty success for an unavailable capability.
5. **Minimal write surface.** `macai_speak` / `macai tts` writes a new audio file and refuses
   an existing file or directory. Everything else is read-only.
6. **The binary is a library user, not a daemon.** No HTTP server, no port, no long-running
   state. MCP is a stdio child of the host.

## MCP protocol contract

These are external contracts; changing them can break clients:

| item | current behavior | why |
|:--|:--|:--|
| `protocolVersion` | supports `2025-06-18` and `2024-11-05`; an unsupported request gets the newest supported version | the spec requires returning your own version rather than echoing an unsupported one |
| `ping` | kept (empty result) | the 2026-07-28 spec removed it from lifecycle, but older clients still send it and would disconnect |
| tool `title` / `annotations` | all 8 tools have them; all except `macai_speak` are `{readOnlyHint:true, openWorldHint:false}` | MCP defaults are pessimistic; hosts otherwise treat every tool as destructive and networked |
| `instructions` | Chinese, under 2 KB, declarative | Claude Code truncates at 4096 chars; some hosts disconnect above 32 KB; imperative instructions can be classified as prompt injection |
| error envelope | `{ok:false, code, message, retryable, remediation}` + `error`/`hint`; MCP `isError:true` | scripts and agents need one shape |

The server implements `initialize`, `notifications/initialized`, `notifications/cancelled`,
`ping`, `tools/list`, and `tools/call`. Adding a protocol version requires checking that
version's lifecycle and method signatures, not just changing a number.

## OCR input paths

- `macai ocr <path>...` — one or more file paths.
- `macai ocr -` — one image from stdin, no temporary file.
- `macai ocr - --frames` — a length-prefixed stream:

```
{ [u32 big-endian length][image bytes] } … [u32 big-endian 0]
```

Rules:

- frame length must be > 0; `0` terminates; EOF also terminates;
- no bytes after the terminator;
- limits: 64 MiB per frame, 64 frames, 256 MiB total; lengths are validated before allocation;
- output is element-for-element identical to passing paths;
- `--frames` is serial and cannot be mixed with real paths.

The stdin path and the file path share the same decode/recognize code; the spec asserts that
both produce identical `width/height/scaled` and per-line `text/confidence/box`.

## Testing philosophy

- Tests assert content, not just "the command did not crash".
- The e2e OCR fixture is generated independently (`textutil` → `qlmanage`), not with the
  same CoreGraphics path used by `selftest`; the two paths should not certify each other.
- Skips are allowed only for environmental conditions: missing speech assets, missing
  translation language packs, and optional fixture generators. Every skip prints its
  remediation command. Skips must not hide a real failure.
- The optional 2560×1440 comparison requires an external fixture generator. Set
  `MACAI_EXPECT_PROBE` to its path; without it, that section skips.
- Client/CLI tests (`macai-spec`) cover argument parsing, JSON envelopes, MCP protocol
  negotiation, tool metadata, language handling, voice selection, output-path safety, OCR
  stdin equivalence and frame-stream parsing.

## Privacy gate

The repository is public and uses a pre-commit scan:

```bash
./scripts/setup-dev.sh          # install the hook once per clone
./scripts/privacy-check.sh --all
```

- generic patterns live in `scripts/privacy-patterns.txt` (tokens, private keys, personal
  email domains, home directories, private network ranges);
- machine-specific patterns go into `.privacy-blocklist.local` (gitignored, never tracked);
- a confirmed false positive can be waived with `privacy-check: allow` at the end of the
  line, and the reason should be obvious;
- commit with a GitHub noreply email; `setup-dev.sh` warns if the repository email is not
  one.

Never add absolute personal paths, internal hostnames, LAN addresses, or screenshots of
private data. Use `~` in documentation.

## Release checklist

1. `swift build -c release` and `./scripts/build.sh` succeed.
2. `./scripts/test.sh` passes (environmental skips are acceptable and printed).
3. `./scripts/privacy-check.sh --all` passes.
4. `README.md` and `README.zh-CN.md` reflect the current CLI/tools.
5. `macai version` matches the tag; tag `vX.Y.Z` on the release commit.
6. The public release is mirrored from the private development repository with a clean
   release branch (no private notes or deployment files).

## Open work

- Measure long-running batch OCR memory behavior.
- Consider a generic HTTP wrapper as an optional example (not part of the binary).
- Keep macOS 26+ as the floor until the STT path can use a non-TCC API on older systems.
