# macai — 把 macOS 自带的 AI 能力装进一个离线二进制

[English](README.md) | **简体中文**

**macOS 里躺着六种可用的 AI 能力。`macai` 把它们变成一条 CLI 命令和一个 MCP 服务器——零第三方依赖、零 API key、零按次费用。**

文字识别、语音识别、语音合成、文本分析、声音分类、离线翻译都藏在系统框架里，脚本和 agent
够不着。`macai` 用一个 Swift 二进制把它们全部包出来：

- **一个二进制，两种形态**：`macai <命令>` 给 shell，`macai mcp` 给 MCP 宿主；
- **离线推理**：Vision / Speech / AVFoundation / NaturalLanguage / SoundAnalysis /
  Translation 全部在进程内调用；没有遥测、不需要 key。唯一的联网动作是 macOS 的语音资产
  一次性下载，而且只在你显式传 `--install-assets` 时才发生；
- **失败不装死**：稳定的 JSON 信封、稳定退出码、可执行的 `remediation`，不返回空结果；
- **为 agent 准备**：MCP 工具带 `title` 与 `annotations`，服务器协商协议版本，instructions 精简。

- [它能做什么](#它能做什么)
- [为什么需要它](#为什么需要它)
- [安装](#安装)
- [接进 MCP 客户端](#接进-mcp-客户端)
- [第一条验证](#第一条验证)
- [MCP 工具](#mcp-工具)
- [CLI](#cli)
- [隐私与安全边界](#隐私与安全边界)
- [对比](#对比)
- [已知限制](#已知限制)
- [开发与测试](#开发与测试)

## 它能做什么

| 能力 | 系统框架 | 产出 |
|:--|:--|:--|
| 文字识别 | Vision `VNRecognizeTextRequest` | 逐行文本 + 置信度 + 像素 bbox；可选条码；最多 30 种语言 |
| 语音识别 | Speech `SpeechTranscriber` / `SpeechAnalyzer`（macOS 26） | 离线转写，支持 `locale` 与 `txt/json/srt` |
| 语音合成 | AVFoundation `AVSpeechSynthesizer` | 系统音色生成音频文件；可调语速/音调 |
| 文本分析 | NaturalLanguage | 语种、分词、词性、命名实体、句子切分 |
| 声音分类 | SoundAnalysis | 约 300 类（语音、笑声、音乐、警报…） |
| 离线翻译 | Translation | 语言包已安装时离线翻译 |

另有 **capabilities**（查看本机就绪状态）与 **selftest**（六项能力端到端自检）。

## 为什么需要它

云端 OCR / 语音 API 很强，但要花钱、要联网、数据要出本机。多模态大模型能读图，但为
「这张截图里写了什么」付 token 很浪费。macOS 本身已有模型，只是锁在 Swift 框架里，没有
CLI 和 MCP 面。

`macai` 就是缺失的那层适配器：

- 不需要 Python/Node 运行时、包管理器、守护进程，二进制内没有 HTTP 服务；
- 模型属于系统，不下载第三方模型。macOS 可能一次性下载自己的语音资产，仅在运行
  `macai stt --install-assets`（或 `selftest --install-assets`）时发生；
- 输出面向脚本与 agent 的 JSON 信封，而不是面向人的一段话；
- 能力不可用时给出确切的修复命令，不假装「识别结果为空」。

## 安装

要求：**macOS 26+**（语音识别使用 `SpeechTranscriber` / `SpeechAnalyzer`）以及 Command
Line Tools 里的 Swift 工具链。

```bash
git clone https://github.com/T-splines/mac-native-ai.git
cd mac-native-ai
./scripts/build.sh      # swift build -c release -> bin/macai
./scripts/install.sh    # 链到 ~/.local/bin/macai
export PATH="$HOME/.local/bin:$PATH"   # 如果 ~/.local/bin 不在 PATH
macai selftest          # 六项能力端到端自检（默认不联网）
```

`selftest` 默认离线；只有传 `--install-assets` 才会为 STT 下载语音资产。没装资产的机器上
STT 会显示环境 SKIP 并给出安装命令；翻译语言包没有下载 API，需要在「翻译」App / 系统设置里
人工触发。

`build.sh` 会做 ad-hoc 签名；签名失效的二进制会被 `taskgated` 直接杀掉。不需要 TCC 授权：
STT 只读音频文件，不打开麦克风。

## 接进 MCP 客户端

`macai` 在 `PATH` 里之后，把这段加进任意 MCP 客户端：

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

- **Claude Code**：`claude mcp add macai -- macai mcp`
- **Claude Desktop**：写进 `claude_desktop_config.json`
- **任意 stdio MCP 客户端**：命令 `macai`，参数 `mcp`

GUI 客户端的 `PATH` 常常不含 `~/.local/bin`，找不到时用绝对路径
`$HOME/.local/bin/macai`。

服务器是由宿主拉起的 stdio 子进程：不监听端口、不接受远程连接、继承宿主权限。

## 第一条验证

装好后给宿主一句话：

> 用 macai 识别这张截图里的文字：`~/Desktop/shot.png`

预期：模型调用 `macai_ocr`，参数是绝对路径和 `zh-Hans,en-US` 之类的语言列表；
100–500 ms 后返回逐行文本、置信度和像素 bbox。全程没有网络请求，也没有把 token 花在 OCR 上。

再验证本机就绪状态：

> 用 macai 看看这台机器现在能做什么

预期：`macai_capabilities` 返回 TTS 音色数、STT 语音资产状态、已装翻译语言对、OCR 语言数。
STT 显示未安装是正常的（首次需要联网下载一次语音资产），按返回的 remediation 跑一次
`macai stt --install-assets --locale zh-CN` 即可。

## MCP 工具

| 工具 | title | 做什么 | 只读 |
|:--|:--|:--|:--|
| `macai_ocr` | 图片文字识别 | 图片 → 逐行文本 + 置信度 + 像素 bbox（可同时识别条码） | 是 |
| `macai_transcribe` | 音频转文字 | 音频 → 文字（离线；`locale` 决定语言；支持 `txt/json/srt`） | 是 |
| `macai_speak` | 语音合成落盘 | 文本 → 新音频文件；已存在的文件或目录一律拒绝 | 否 |
| `macai_voices` | 可用音色列表 | 系统音色，可按语言过滤 | 是 |
| `macai_translate` | 离线翻译 | 文本 → 目标语言（需系统语言包） | 是 |
| `macai_nlp` | 文本分析 | 语种 / 分词 / 词性 / 实体 / 句子 | 是 |
| `macai_sound` | 声音分类 | 音频 → 声音类别（约 300 类） | 是 |
| `macai_capabilities` | 本机能力状态 | 音色、STT 资产、翻译语言包、OCR 语言 | 是 |

除 `macai_speak` 外全部声明
`annotations: {readOnlyHint: true, openWorldHint: false}`；`macai_speak` 声明
`{readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false}`。
MCP 默认值是悲观值，显式声明后宿主可以放心自动执行前 7 个工具。

服务器声明支持协议版本 `2025-06-18` 与 `2024-11-05`；不支持的版本回最新支持版，不谎报。
`initialize` 会下发一段 2 KB 以内的中文 instructions，说明工具选择与三条硬约束。

## CLI

```bash
macai ocr screenshot.png                      # 文字 + 置信度 + 像素 bbox
macai ocr - --frames < frames.bin             # 一次进程识别 N 张图
macai stt voice.wav --locale zh-CN            # 音频 → 文字，完全离线
macai tts --text "下午三点开会" --out out.wav
macai translate --to zh-Hans --text "offline"
macai nlp "Tim Cook works at Apple Inc."      # 语种 / 分词 / 词性 / 实体 / 句子
macai sound clip.wav --top 3                  # 语音 / 笑声 / 音乐 / 警报…
macai mcp                                     # MCP stdio 服务器（8 个工具）
macai selftest                                # 六项能力端到端自检
macai help
```

每条命令都支持 `--json`（`{"ok":true,"data":…}`）与稳定退出码：

| 退出码 | 含义 |
|:--|:--|
| `0` | 成功 |
| `1` | 参数 / 用法错误 |
| `2` | 运行失败 |
| `3` | 能力不可用（语音资产或翻译语言包未装） |

失败统一走一个信封：

```json
{"ok": false, "code": 3, "message": "…", "retryable": false, "remediation": "…怎么修…"}
```

参数错误与能力不可用的 `retryable` 为 `false`，多数运行失败为 `true`。MCP 侧把同一信封
塞进 `content[0].text`，`isError: true` 照旧。

### 从 stdin 批量 OCR

按窗口分块 OCR 时，每张图起一个进程会重复付出 Vision 初始化成本。`macai ocr -` 从 stdin
读一张图；`macai ocr - --frames` 读长度前缀帧流：

```
{ [u32 大端长度][图片字节] } … [u32 大端 0]
```

- 长度必须 > 0；`0` 是终止符；EOF 也可结束；
- 终止符之后不得再有字节；
- 上限：单帧 64 MiB、64 帧、总量 256 MiB；长度在分配内存前校验；
- 输出与逐路径传参逐元素一致。

在 Apple Silicon / macOS 26 上，8 张 2560×1440：8 次进程 3.15 s，1 次进程 2.22 s，
约 **1.4×**。提速来自每进程一次的 Vision 初始化，不是单张 OCR 变快。

## 隐私与安全边界

- **数据不出本机。** 六项能力全部是进程内系统框架调用；识别与翻译不会上传内容。项目里
  唯一的联网动作是 macOS 的语音资产一次性下载，且只在
  `macai stt --install-assets` / `macai selftest --install-assets` 时发生。没有遥测、没有
  API key、没有账号。
- **不需要凭据。** 仓库没有读取密钥的路径；`.env`、证书、私钥由 `.gitignore` 与 pre-commit
  隐私扫描兜底。
- **只有一个用户可控的写文件入口。** `macai_speak` / `macai tts` 写新音频文件；目标是
  已存在文件或目录时直接拒绝，不覆盖、不删除。其余 7 个 MCP 工具只读。
- **只识别，不理解。** 不做图像语义、图像生成、文档推理。「图里写了什么」归它，
  「图说明了什么」不归它。
- **不可用就明确失败。** 语音资产或翻译语言包缺失时返回 `code: 3` + 修复命令，不返回空字符串。
  语言包只能在系统设置或「翻译」App 里人工触发，本项目不会偷偷联网下载。

## 对比

| | 云端 API | 多模态大模型 | **macai** |
|:--|:--|:--|:--|
| 成本 | 按次计费 | token 计费 | **API 费用 0** |
| 联网 | 必须 | 必须 | **不需要** |
| 隐私 | 数据出本机 | 数据出本机 | **不出本机** |
| 延迟 | 网络往返 | 秒级 | **毫秒级**（OCR 约 83–472 ms） |
| 语义理解 | — | 是 | **否**（只做识别与转换） |

它不替代推理模型；它的价值是：**系统已经能做好的事，不要再付 token。**

## 已知限制

1. **STT 一次只认一种语言。** 系统语音模型按 locale 加载；中英混说可能丢拉丁词
   （「这台 Mac」→「这台」）。英文素材请用 `--locale en-US` 再跑一遍。
2. **STT 语音资产需要一次性下载。** 首次使用某语言需联网下载（几十 MB，由 macOS 完成）；
   `macai selftest` 默认**不会**下载，除非传 `--install-assets`。装好后完全离线；
   缺失时明确报错并给出安装命令。
3. **翻译语言包没有下载 API。** 只能在「翻译」App / 系统设置里人工触发一次；缺失时退出码 3
   并给出手工指引。
4. **STT 不做语种识别。** 音频没有语言标签；默认 `zh-CN` 是便利默认值，不是通用默认。
5. **TTS 容器转换依赖 `afconvert`。** 支持 `wav/aiff/m4a/caf` 容器；不支持 mp3，需要时请
   外部转换。默认格式是 wav。
6. **Vision 的置信度恒为 0.5。** 这是系统行为，不要拿它当质量阈值。
7. **批量 OCR 的内存回落尚未充分测量。** 单次调用会对大图降采样，长跑批量仍待观察。
8. **`--frames` 是串行识别。** 省的是进程启动与 Vision 初始化，不是单张 OCR 时间；
   不能与真实路径混用。
9. **macOS 26+ 是硬底线**：语音识别走 `SpeechTranscriber` / `SpeechAnalyzer`。
10. **不做图像语义理解与生成。** 那类任务请交给多模态模型。

## 开发与测试

```bash
./scripts/test.sh          # 构建 + spec + selftest + e2e
swift build && ./.build/debug/macai-spec    # 145 项 spec 断言
./tests/e2e.sh                              # 99 项断言（环境跳过随机器变化）
macai selftest                              # 6 项能力自检
```

完整测试口径、架构与 MCP 协议契约见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。环境跳过
包括语音资产未装、翻译语言包未装、可选 fixture 生成器缺失；都会打印修复命令，不允许用
skip 掩盖失败。

## 许可

MIT，见 [LICENSE](LICENSE)。许可证覆盖本仓库源码；`macai` 运行时依赖 Apple 系统框架与
macOS 26+，这些不随仓库分发，使用者需自备符合 Apple 授权条件的设备与系统。
