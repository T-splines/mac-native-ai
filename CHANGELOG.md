# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-11-16

### Fixed

- CI: an empty `stt --locales` list on a macOS runner without speech locales is now an
  environmental skip, not a test failure. The product behavior is unchanged.

## [0.1.0] - 2026-11-16

First public release.

### Added

- One Swift binary exposing six macOS system capabilities: OCR, speech-to-text,
  text-to-speech, text analysis, sound classification and offline translation.
- CLI with stable JSON envelopes and exit codes `0/1/2/3`.
- MCP stdio server with eight tools, tool annotations, protocol-version negotiation and
  compact instructions.
- Batch OCR over stdin, including a length-prefixed frame stream.
- `capabilities` and `selftest` commands for on-device readiness checks.
- Environment-gated test suite: spec runner, capability selftest and end-to-end assertions.

### Safety

- `macai tts` / `macai_speak` refuses to overwrite an existing file or replace a directory.
- `macai sound --top` rejects values below 1 with a usage error instead of trapping.
- `macai selftest` does not download speech assets unless `--install-assets` is passed.
- Privacy scan covers modern token shapes, home-directory paths and private hostnames;
  see `scripts/privacy-patterns.txt`.
