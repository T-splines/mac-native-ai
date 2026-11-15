# Contributing

Thanks for taking a look. `macai` is a small SwiftPM project with a strict "no third-party
dependencies" rule.

## Development

Requirements: macOS 26+, Command Line Tools with Swift.

```bash
git clone https://github.com/T-splines/mac-native-ai.git
cd mac-native-ai
./scripts/setup-dev.sh      # install the privacy pre-commit hook
swift build
./.build/debug/macai-spec   # 145 spec assertions
./tests/e2e.sh              # 99 assertions (environmental skips vary)
```

The full suite is `./scripts/test.sh`; it also runs `macai selftest`. Environmental skips
(missing speech assets, translation packs, or optional fixture generators) are allowed and
printed with a fix command.

## Pull requests

- Keep one logical change per commit. Use `feat:` / `fix:` / `test:` / `docs:` / `chore:`
  prefixes and explain *why*.
- Add a regression test for every fix. For CLI behavior, extend `macai-spec` and/or
  `tests/e2e.sh`; for MCP contracts, extend the protocol assertions.
- Do not add SPM dependencies, a daemon, an HTTP server or HTTP client in the binary, or a
  network path other than macOS's explicit speech-asset installation.
- Keep errors on the existing envelope and exit-code contract.
- Update README (English and Chinese) when user-facing behavior changes.
- Run `./scripts/privacy-check.sh --all` before pushing. No personal paths, internal
  hostnames, LAN addresses, tokens or private screenshots.

## Code style

- Swift 5 language mode (the manifest sets it explicitly).
- Comments explain *why* (a system constraint, a worked-around bug), not *what*.
- Prefer small pure helpers for parsing/formatting; keep system-framework calls at the edge.
