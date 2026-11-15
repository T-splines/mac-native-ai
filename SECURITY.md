# Security policy

## Supported versions

The latest release on the `main` branch is supported. Pre-release versions are provided for
testing only.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's private
vulnerability reporting:

<https://github.com/T-splines/mac-native-ai/security/advisories/new>

Include the affected version, a minimal reproduction and the impact you observed. You will
get an acknowledgement as soon as possible; please allow time for a fix and a coordinated
disclosure.

## Scope

`macai` is a local CLI and a stdio MCP server. Its purpose is to keep data on-device:

- all six capabilities run in-process on Apple system frameworks; the binary has no HTTP
  client and no telemetry. The only network action is macOS's one-time speech-asset download,
  triggered only by `macai stt --install-assets` / `macai selftest --install-assets`;
- no credentials or API keys are read, stored or transmitted;
- the only write path is `macai_speak` / `macai tts`, which creates a new audio file and
  refuses to overwrite an existing file or replace a directory;
- the MCP server is a child process launched by the host, does not listen on a port and
  inherits the host's permissions; it can read the paths it is given.

Vulnerabilities in macOS frameworks, Vision/Speech/Translation models or the MCP host should
be reported to Apple or to that host's project.
