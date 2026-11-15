import Foundation

/// 命令行入口：所有能力都在这一个二进制里，没有第二套实现。
public enum CLI {
    public static let helpText = """
    macai — macOS 系统内置 AI 能力（零第三方依赖，不联网、不需要 API key）

    用法:
      macai <命令> [参数...]

    命令:
      ocr <图片...>            文字识别（Vision）。--lang zh-Hans,en-US --fast --max-width 2400 --barcode
                               --prefer-background --no-correction --candidates
                               路径写 - 从 stdin 读图（cat img.png | macai ocr -），可与真实路径混用
                               - 加 --frames：stdin 按「长度前缀帧流」一次读多张图，一次进程识别 N 张
                               （--frames 只对 stdin 有效，必须与 - 同用；不能与真实路径混用）
                               帧流格式: { [u32 大端长度][该长度的图片字节] } … [u32 大端 0]
                                 每帧长度必须 > 0；u32 0 是终止符；EOF 也可正常结束；
                                 终止符之后不得再有字节（有则报错）；单帧 ≤ 64 MiB、帧数 ≤ 64、总量 ≤ 256 MiB
                               构造示例（Python 一行，img1…imgN 换成真实路径）:
                                 python3 -c 'import struct,sys;d=[open(p,"rb").read() for p in sys.argv[1:]];sys.stdout.buffer.write(b"".join(struct.pack(">I",len(x))+x for x in d)+struct.pack(">I",0))' img1.png img2.png | macai ocr - --frames --json
                               输出与 `macai ocr img1.png img2.png` 逐元素一致；每页 file 记 <stdin>#1 <stdin>#2 …
      nlp <文本>               语种/分词/词性/实体/句子。--detect --tokens --entities --sentences --all(默认)
                               --text "…" 传文本，或直接给位置参数
      tts                      语音合成（AVSpeechSynthesizer）。--text "…" | --input <文件> --out <文件>
                               --voice <名字|identifier> --lang zh-CN --rate 0..1 --pitch 0.5..2 --engine av|say
                               --format wav|aiff|m4a|caf
      voices                   列出系统音色。--lang zh --gender female
                               --sample 给每个音色合成试听样音（--out-dir DIR --text "…{name}…"）
                               另有 --rate / --pitch，可用来把同一个音色调得更年轻/更甜
      stt <音频>               语音识别（Speech SpeechTranscriber，离线）。--locale zh-CN --format txt|json|srt
                               --out <文件> --timeout 300 --raw
      stt --status             查看语音资产安装状态（--locale zh-CN）
      stt --install-assets     下载该语言的语音资产（首次需联网一次）
      stt --locales            列出系统语音识别支持的语言
      sound <音频>             声音分类（SoundAnalysis，约 300 类）。--top 3
      translate                翻译（系统 Translation，完全离线）。--text "…" --from en --to zh-Hans
                               --status 列出语言包状态（--from/--to 可选）
      selftest                 真实能力的端到端自检（PASS/FAIL/SKIP 表；默认不联网）
      selftest --install-assets  允许自检为 STT 下载语音资产（会联网一次）
      mcp                      MCP stdio 服务器（给 agent 宿主用）
      version                  版本
      help                     本帮助

    通用:
      --json                   机器可读输出（{"ok":true,"data":…} / {"ok":false,"error":…}）

    退出码: 0 成功 / 1 参数错误 / 2 运行失败 / 3 能力不可用（资产或语言包未装）
    """

    public static func run(_ argv: [String]) -> Int32 {
        var arguments = argv
        let command = arguments.isEmpty ? "help" : arguments.removeFirst()
        let args = Args(arguments)
        let json = args.bool("json")

        if args.bool("help") && command != "help" {
            print(helpText)
            return ExitCode.ok
        }

        do {
            switch command {
            case "ocr": return try runOCR(args, json: json)
            case "nlp": return try runNLP(args, json: json)
            case "tts", "speak": return try runTTS(args, json: json)
            case "voices": return try runVoices(args, json: json)
            case "stt", "transcribe": return try runSTT(args, json: json)
            case "sound": return try runSound(args, json: json)
            case "translate": return try runTranslate(args, json: json)
            case "selftest": return SelfTest.run(json: json, allowNetworkAssets: args.bool("install-assets"))
            case "mcp": return MCPServer.run()
            case "version", "--version", "-v":
                if json { Out.ok(["version": Support.version(), "platform": "macOS"], json: true) }
                else { print("macai \(Support.version())") }
                return ExitCode.ok
            case "help", "--help", "-h":
                print(helpText)
                return ExitCode.ok
            default:
                throw MacAIError("未知命令 '\(command)'", hint: "跑 `macai help` 看全部命令", code: ExitCode.usage)
            }
        } catch let error as MacAIError {
            Out.fail(error, json: json)
            return error.code
        } catch {
            Out.fail(MacAIError("\(error)"), json: json)
            return ExitCode.runtime
        }
    }

    // MARK: - ocr

    static func runOCR(_ args: Args, json: Bool) throws -> Int32 {
        // --frames 是 stdin 的帧流形态，不是自动探测：必须显式写 -，且不与真实路径混用
        // （单图 stdin 走原路径，向后兼容优先）。在任何读 stdin / 校验位置参数之前拦截，
        // 这样 `macai ocr --frames`（连 - 都没写）也给出「只对 stdin 有效」而不是「没有给图片路径」。
        let framesMode = args.bool("frames")
        if framesMode {
            guard args.positional.contains("-") else {
                throw MacAIError("--frames 只对 stdin 有效，需要同时写 -",
                                 hint: "用法: <构造帧流> | macai ocr - --frames（--frames 只对 stdin 有效，不能配真实路径）",
                                 code: ExitCode.usage)
            }
            guard args.positional.count == 1 else {
                throw MacAIError("--frames 不能与真实路径混用（也只能有一个 -）",
                                 hint: "帧流模式一次只读 stdin：把全部图片放进帧流，写成 macai ocr - --frames",
                                 code: ExitCode.usage)
            }
        }
        guard !args.positional.isEmpty else {
            throw MacAIError("没有给图片路径", hint: "macai ocr <图片...> [--lang zh-Hans,en-US]（路径写 - 可从 stdin 读图）", code: ExitCode.usage)
        }
        // stdin 只能读一次：'-' 出现两次直接参数错。必须在任何读 stdin 之前拦截。
        guard args.positional.filter({ $0 == "-" }).count <= 1 else {
            throw MacAIError("'-' 只能出现一次",
                             hint: "stdin 只能读一次；要识别多张图请用真实路径，例如: macai ocr a.png b.png",
                             code: ExitCode.usage)
        }
        var options = OCREngine.Options()
        options.languages = args.list("lang")
        options.fast = args.bool("fast")
        options.usesLanguageCorrection = !args.bool("no-correction")
        options.maxWidth = args.int("max-width", default: 2400)
        options.preferBackground = args.bool("prefer-background")
        options.barcodes = args.bool("barcode") || args.bool("barcodes")

        var pages: [[String: Any]] = []
        var humanLines: [String] = []
        if framesMode {
            // 边读边校验（先校验再分配），超限/截断在读字节之前或之中就报错。
            let frames = try FrameStream.readFromStdin()
            guard !frames.isEmpty else {
                throw MacAIError("stdin 是空的",
                                 hint: "帧流至少要有 1 帧：{ [u32 大端长度][图片字节] } … [u32 大端 0]，见 macai help 的 ocr 一节",
                                 code: ExitCode.usage)
            }
            for (offset, frame) in frames.enumerated() {
                let page = try OCREngine.recognize(frame: frame, index: offset + 1, options: options)
                pages.append(OCREngine.json(page, includeCandidates: args.bool("candidates")))
                if frames.count > 1 { humanLines.append("# \(page.file)") }
                humanLines.append(page.text)
            }
        } else {
            for path in args.positional {
                let page: OCREngine.Page
                if path == "-" {
                    page = try OCREngine.recognize(stdinData: Support.readStdinData(), options: options)
                } else {
                    page = try OCREngine.recognize(path: path, options: options)
                }
                pages.append(OCREngine.json(page, includeCandidates: args.bool("candidates")))
                if args.positional.count > 1 { humanLines.append("# \(path == "-" ? "<stdin>" : path)") }
                humanLines.append(page.text)
            }
        }
        let payload: [String: Any] = pages.count == 1 ? pages[0] : ["pages": pages]
        if json {
            Out.ok(payload, json: true)
        } else {
            Out.ok(payload, json: false, human: humanLines.joined(separator: "\n"))
        }
        return ExitCode.ok
    }

    // MARK: - nlp

    static func runNLP(_ args: Args, json: Bool) throws -> Int32 {
        var text = args.text ?? ""
        if text.isEmpty, let stdinPath = args.string("stdin") {
            text = try Support.readText(stdinPath)
        }
        if text.isEmpty { text = args.positional.joined(separator: " ") }
        guard !text.isEmpty else {
            throw MacAIError("没有给文本", hint: "macai nlp \"要分析的文本\" 或 --text \"…\"", code: ExitCode.usage)
        }
        let analysis = NLPEngine.analyze(text)
        if json {
            Out.ok(NLPEngine.json(analysis), json: true)
            return ExitCode.ok
        }
        var lines: [String] = []
        let wantAll = args.bool("all") || (!args.bool("detect") && !args.bool("tokens") && !args.bool("entities") && !args.bool("sentences"))
        if wantAll || args.bool("detect") {
            let hypotheses = analysis.languageHypotheses.prefix(3).map { "\($0.0)=\(String(format: "%.2f", $0.1))" }.joined(separator: " ")
            lines.append("语种: \(analysis.language ?? "?") (\(hypotheses))")
        }
        if wantAll || args.bool("tokens") {
            let tokens = analysis.tokens.map { token -> String in
                var suffix = token.pos.map { "/\($0)" } ?? ""
                if let entity = token.entity, entity != "Other" { suffix += "[\(entity)]" }
                return token.text + suffix
            }
            lines.append("分词(\(analysis.tokens.count)): \(tokens.joined(separator: " "))")
        }
        if args.bool("entities") || wantAll {
            lines.append("实体: \(analysis.entities.isEmpty ? "（无）" : analysis.entities.joined(separator: ", "))")
        }
        if wantAll || args.bool("sentences") {
            lines.append("句子(\(analysis.sentences.count)):")
            for (index, sentence) in analysis.sentences.enumerated() { lines.append("  \(index + 1). \(sentence)") }
        }
        Out.ok(NLPEngine.json(analysis), json: false, human: lines.joined(separator: "\n"))
        return ExitCode.ok
    }

    // MARK: - tts / voices

    static func runTTS(_ args: Args, json: Bool) throws -> Int32 {
        var options = TTSEngine.Options()
        if let text = args.text {
            options.text = text
        } else if let input = args.string("input") {
            options.text = try Support.readText(input)
        } else if !args.positional.isEmpty {
            options.text = args.positional.joined(separator: " ")
        } else {
            throw MacAIError("没有文本", hint: "传 --text \"…\" 或 --input <文本文件>", code: ExitCode.usage)
        }
        options.voice = args.string("voice")
        options.language = Support.normalizeLanguageTag(args.string("lang"))
        options.rate = args.has("rate") ? args.double("rate", default: 0.5) : nil
        options.pitch = args.has("pitch") ? args.double("pitch", default: 1.0) : nil
        options.volume = args.has("volume") ? args.double("volume", default: 1.0) : nil
        options.engine = args.string("engine", default: "av")
        options.format = args.string("format")
        let format = (options.format ?? "wav").lowercased()
        options.outputPath = args.string("out")
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("macai-tts-\(UUID().uuidString.prefix(8)).\(format)").path

        let result = try TTSEngine.synthesize(options)
        Out.ok(TTSEngine.json(result), json: json,
               human: "\(result.path)\n\(result.bytes) B · \(String(format: "%.2f", result.durationSeconds))s · \(Int(result.sampleRate))Hz · voice=\(result.voiceName) · \(Int(result.milliseconds))ms")
        return ExitCode.ok
    }

    static func runVoices(_ args: Args, json: Bool) throws -> Int32 {
        let prefix = args.string("lang")?.lowercased()
        let gender = args.string("gender")
        let voices = TTSEngine.voices(languagePrefix: prefix, gender: gender)

        if args.bool("sample") {
            guard !voices.isEmpty else {
                throw MacAIError("没有匹配的音色", hint: "macai voices --lang zh --gender female", code: ExitCode.runtime)
            }
            let dir = args.string("out-dir") ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("macai-voice-samples-\(UUID().uuidString.prefix(8))").path
            let template = args.string("text") ?? "你好呀，我是{name}，很高兴认识你。"
            let format = args.string("format", default: "wav")
            let rate = args.has("rate") ? args.double("rate", default: 0.5) : nil
            let pitch = args.has("pitch") ? args.double("pitch", default: 1.0) : nil
            let samples = TTSEngine.samples(voices: voices, textTemplate: template, outputDir: dir,
                                            format: format, rate: rate, pitch: pitch)
            if json {
                Out.ok(["count": samples.count, "out_dir": Support.expand(dir), "samples": samples.map(TTSEngine.json)], json: true)
                return ExitCode.ok
            }
            var lines = ["样本目录: \(Support.expand(dir))（\(samples.count) 个音色）"]
            for sample in samples {
                let mark = sample.error == nil ? "✅" : "❌"
                let genderLabel = sample.voice.gender == "unspecified" ? "?" : sample.voice.gender
                lines.append("\(mark) \(sample.voice.language) \(sample.voice.name) (\(genderLabel), Q\(sample.voice.quality)\(sample.voice.novelty ? ", novelty" : "")) → \(sample.path ?? sample.error ?? "")")
            }
            Out.ok(["count": samples.count], json: false, human: lines.joined(separator: "\n"))
            return ExitCode.ok
        }

        if json {
            Out.ok(["count": voices.count, "voices": voices.map {
                ["id": $0.identifier, "name": $0.name, "language": $0.language,
                 "quality": $0.quality, "gender": $0.gender, "novelty": $0.novelty]
            }], json: true)
            return ExitCode.ok
        }
        guard !voices.isEmpty else {
            Out.fail(MacAIError("没有匹配的音色", hint: "macai voices（不带 --lang 看全部）"), json: false)
            return ExitCode.runtime
        }
        var lines = ["共 \(voices.count) 个音色（Q = 系统音质档，novelty = 趣味/老式音色；试听：macai voices --sample --lang zh）:"]
        for voice in voices {
            let genderLabel = voice.gender == "unspecified" ? "?" : voice.gender
            lines.append("  \(voice.language)  \(voice.name)  [\(genderLabel), Q\(voice.quality)\(voice.novelty ? ", novelty" : "")]  \(voice.identifier)")
        }
        Out.ok(["count": voices.count], json: false, human: lines.joined(separator: "\n"))
        return ExitCode.ok
    }

    // MARK: - stt

    static func runSTT(_ args: Args, json: Bool) throws -> Int32 {
        let locale = Support.normalizeLanguageTag(args.string("locale")) ?? "zh-CN"

        if args.bool("locales") {
            let locales = STTEngine.supportedLocales()
            Out.ok(["count": locales.count, "locales": locales], json: json,
                   human: "支持 \(locales.count) 种语言:\n  " + locales.joined(separator: ", "))
            return ExitCode.ok
        }
        if args.bool("status") {
            let payload = try STTEngine.jsonAssetState(locale)
            let installed = (payload["installed"] as? Bool) ?? false
            Out.ok(payload, json: json,
                   human: "locale=\(payload["locale"] ?? locale) 资产状态=\(payload["asset_state"] ?? "?")\(installed ? "（已安装，可离线转写）" : "（未安装：跑 macai stt --install-assets --locale \(locale)）")")
            return ExitCode.ok
        }
        if args.bool("install-assets") {
            let payload = try STTEngine.installAssets(locale: locale)
            Out.ok(payload, json: json,
                   human: "locale=\(payload["locale"] ?? locale) 资产: \(payload["asset_state_before"] ?? "?") → \(payload["asset_state_after"] ?? "?")")
            return ExitCode.ok
        }

        guard let audio = args.positional.first ?? args.string("input") else {
            throw MacAIError("没有给音频文件", hint: "macai stt <音频> [--locale zh-CN]", code: ExitCode.usage)
        }
        var options = STTEngine.Options()
        options.audioPath = audio
        options.locale = locale
        options.timeout = args.double("timeout", default: 300)
        options.installAssets = args.bool("install-assets")
        options.rawSpacing = args.bool("raw")

        let result = try STTEngine.transcribe(options)
        let format = args.string("format", default: "txt").lowercased()
        let body: String
        switch format {
        case "json": body = JSONOut.render(STTEngine.json(result))
        case "srt": body = STTEngine.srt(result)
        default: body = result.text
        }
        if let out = args.string("out") {
            try Support.writeText(body + (format == "txt" ? "\n" : ""), to: out)
        }
        if json {
            Out.ok(STTEngine.json(result), json: true)
        } else {
            print(body)
        }
        return ExitCode.ok
    }

    // MARK: - sound

    static func runSound(_ args: Args, json: Bool) throws -> Int32 {
        guard let audio = args.positional.first ?? args.string("input") else {
            throw MacAIError("没有给音频文件", hint: "macai sound <音频> [--top 3]", code: ExitCode.usage)
        }
        let top = args.int("top", default: 3)
        let result = try SoundEngine.classify(path: audio, top: top)
        if json {
            Out.ok(SoundEngine.json(result, top: top), json: true)
            return ExitCode.ok
        }
        guard !result.windows.isEmpty else {
            Out.fail(MacAIError("没有分析出任何声音类别", hint: "确认音频里有实际内容"), json: false)
            return ExitCode.runtime
        }
        var lines = ["\(result.file) · \(String(format: "%.2f", result.duration))s · \(result.windows.count) 个窗口"]
        for (label, confidence) in result.labels.prefix(top) {
            lines.append(String(format: "  %-24@ %.3f", label as NSString, confidence))
        }
        Out.ok(SoundEngine.json(result, top: top), json: false, human: lines.joined(separator: "\n"))
        return ExitCode.ok
    }

    // MARK: - translate

    static func runTranslate(_ args: Args, json: Bool) throws -> Int32 {
        if args.bool("status") {
            let statuses = try TranslateEngine.statusMatrix(source: Support.normalizeLanguageTag(args.string("from")),
                                                            target: Support.normalizeLanguageTag(args.string("to")))
            let installed = TranslateEngine.installedHints(statuses)
            if json {
                Out.ok(["installed": installed, "pairs": statuses.map {
                    ["source": $0.source, "target": $0.target, "state": $0.state]
                }], json: true)
                return ExitCode.ok
            }
            var lines = ["语言包状态（共 \(statuses.count) 对）:"]
            for status in statuses where status.installed { lines.append("  ✅ \(status.source) → \(status.target)") }
            let pending = statuses.filter { !$0.installed && $0.supported }
            if !pending.isEmpty {
                lines.append("  ⚠️ 未安装 \(pending.count) 对（如 \(pending[0].source) → \(pending[0].target)）；\(TranslateEngine.installHint(pending[0].source, pending[0].target))")
            }
            Out.ok(["installed": installed], json: false, human: lines.joined(separator: "\n"))
            return ExitCode.ok
        }

        let text = args.text ?? args.positional.joined(separator: " ")
        guard !text.isEmpty else {
            throw MacAIError("没有待翻译文本", hint: "macai translate --to zh-Hans --text \"…\"", code: ExitCode.usage)
        }
        guard let target = Support.normalizeLanguageTag(args.string("to")) else {
            throw MacAIError("缺少目标语言", hint: "macai translate --to zh-Hans \"…\"", code: ExitCode.usage)
        }
        let source = Support.normalizeLanguageTag(args.string("from"))
        let result = try TranslateEngine.translate(text: text, source: source, target: target,
                                                    timeout: args.double("timeout", default: 180))
        Out.ok(TranslateEngine.json(result), json: json,
               human: "\(result.sourceLanguage) → \(result.targetLanguage)\n\(result.targetText)")
        return ExitCode.ok
    }
}

extension Args {
    /// `--text` 便捷读取：支持 `--text @file` 从文件读。
    var text: String? {
        guard let raw = string("text") else { return nil }
        if raw.hasPrefix("@") {
            return try? Support.readText(String(raw.dropFirst()))
        }
        return raw
    }
}
