import Foundation

/// MCP（Model Context Protocol）stdio 服务器：让 agent 直接把这台 Mac 的系统能力当工具调用，
/// 不必拼 shell 引号、不必解析人类可读输出。
public enum MCPServer {
    /// 本服务器**真正实现**过的协议版本，按新→旧排列（`[0]` 即协商时回落的目标）。
    ///
    /// 为什么不是一个常量：MCP lifecycle 规定「支持请求的版本 → 原样回；不支持 → MUST 回一个自己支持的版本」。
    /// 无脑回显等于谎报能力 —— 客户端要 2025-11-25、服务器答 2025-11-25，客户端随后去调 `resources/*`、
    /// `prompts/*` 只会拿到零散的 -32601，是典型的静默失败。
    ///
    /// 列表里能放谁，取决于方法面而不是发布日期：macai 只做
    /// initialize / notifications/initialized / ping / tools/list / tools/call，
    /// 这几个方法在 2025-06-18 与 2024-11-05 里语义完全一致，所以两个版本都能承诺。
    /// 加新版本前先核对那一版的 lifecycle 与方法签名，**不要只改数字**。
    public static let supportedProtocolVersions = ["2025-06-18", "2024-11-05"]

    /// 协商：命中就回请求值（客户端可以按自己的版本语义发请求），未命中回我们最新的。
    public static func negotiateProtocolVersion(_ requested: String?) -> String {
        let latest = supportedProtocolVersions[0]
        guard let requested, !requested.isEmpty else { return latest }
        return supportedProtocolVersions.contains(requested) ? requested : latest
    }

    public static func run() -> Int32 {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let message = JSONOut.parse(trimmed) as? [String: Any] else {
                respond(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "JSON 解析失败"]])
                continue
            }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                let negotiated = negotiateProtocolVersion(params["protocolVersion"] as? String)
                respond(id: id, result: [
                    "protocolVersion": negotiated,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "macai", "version": Support.version()],
                    "instructions": instructions,
                ])
            case "notifications/initialized", "notifications/cancelled", "initialized":
                continue
            case "ping":
                // 仅为兼容保留：2026-07-28 版规范已把 `ping` 从 lifecycle 移除（改为各端自行保活），
                // 但一些旧客户端仍在发，删掉会让它们在握手后直接断连。空 result 是规范要求的形状。
                respond(id: id, result: [:])
            case "tools/list":
                respond(id: id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                do {
                    let text = try call(name: name, arguments: arguments)
                    respond(id: id, result: ["content": [["type": "text", "text": text]]])
                } catch let error as MacAIError {
                    // 错误信封与 CLI 共用一份（JSONOut.errorPayload）：ok/code/message/retryable/remediation，
                    // 外加 error/hint 两个兼容别名，与项目内其它 CLI 的字段名保持一致。
                    // isError 仍然置 true —— MCP 客户端靠它判断工具层失败（不是协议层错误）。
                    respond(id: id, result: [
                        "content": [["type": "text", "text": JSONOut.render(JSONOut.errorPayload(error))]],
                        "isError": true,
                    ])
                } catch {
                    // 非 MacAIError 的意外异常：没有退出码可依，按「运行失败」上报（可重试）。
                    let unexpected = MacAIError("\(error)", code: ExitCode.runtime)
                    respond(id: id, result: [
                        "content": [["type": "text", "text": JSONOut.render(JSONOut.errorPayload(unexpected))]],
                        "isError": true,
                    ])
                }
            default:
                if id != nil {
                    respond(id: id, error: ["code": -32601, "message": "未知方法: \(method)"])
                }
            }
        }
        return ExitCode.ok
    }

    // MARK: - 工具面

    /// 握手时下发给客户端的 server instructions。
    ///
    /// 长度纪律：Claude Code 在 4096 字符处截断，部分客户端对 instructions 有 32 KB 上限、
    /// 超过会直接断连 —— 所以这里只留三件事（是什么 / 怎么选工具 / 硬约束），目标 1–2 KB，
    /// e2e 里有断言把关。
    ///
    /// 措辞纪律：全部用陈述句。Anthropic 目录审核把工具描述与 instructions 里的祈使式指令
    /// （「你必须先调用 X」）判为 prompt injection，所以这里写的是"什么时候用哪个"这类事实，
    /// 而不是命令模型做事的句子。
    public static let instructions = """
    macai 把 macOS 内置的 AI 能力开放给本机：文字识别、语音转文字、语音合成、离线翻译、\
    文本分析（分词/词性/实体/语种）、声音分类。全部跑在系统框架上，不联网、不需要 key、不消耗 token，\
    毫秒级返回。它只做识别与转换，不做语义理解、图像理解与图像生成 —— 那类任务不归它管。

    工具分工与替代关系：
    - 图片里的文字、条码 → macai_ocr。fast:true 约快 5 倍、精度略降，适合整屏截图；单张精确识别用默认值。
      大图自动降采样到 2400px 宽。
    - 音频里说了什么 → macai_transcribe。locale 决定识别语言（默认 zh-CN），一次只认一种语言：
      中文素材 zh-CN，英文素材 en-US。中英混说会丢拉丁词（实测「这台 Mac」→「这台」），
      混说素材换 en-US 再跑一遍更稳。
    - 要一段语音 → macai_speak。不给音色时按文本语种自动挑；指定音色先用 macai_voices 列举。
    - 文本翻译 → macai_translate，需要该语言对的系统语言包已就绪。
    - 分词/词性/实体/语种 → macai_nlp；声音分类（语音/笑声/音乐/警报）→ macai_sound。
    - 不确定某能力在这台机器上是否就绪 → macai_capabilities：返回 TTS 音色数、STT 语音资产状态、
      已装翻译语言对、OCR 支持语言数。

    三条硬约束（环境事实）：
    1. ok:false 且 code:3（MCP 侧是 isError:true + code:3）表示该能力当前不可用：语音资产或翻译语言包没装。
       这类算 retryable:false，重试不会变好。
    2. 语音资产可用 `macai stt --install-assets --locale <语言>` 一次性下载；翻译语言包没有下载 API，
       只能在系统设置或「翻译」App 里人工触发。两者装好后都完全离线。
    3. 失败一律走 ok:false 信封，带 code / retryable / remediation，不会静默降级成空结果。
    """

    public static var tools: [[String: Any]] {
        [
            tool("macai_ocr", "图片文字识别",
                 "识别图片中的文字（macOS Vision，离线、不花 token）。返回逐行文本、置信度与像素 bbox，可选条码。",
                 ["path": prop("string", "图片路径（png/jpg/heic/tiff/pdf 首页等）"),
                  "lang": prop("string", "逗号分隔的识别语言，如 zh-Hans,en-US；留空用系统默认"),
                  "fast": prop("boolean", "true 用快速模式（约 1/5 耗时，精度略降）"),
                  "max_width": prop("integer", "超过该宽度先降采样，默认 2400"),
                  "barcodes": prop("boolean", "同时识别条码/二维码")],
                 required: ["path"], annotations: readOnly),
            tool("macai_transcribe", "音频转文字",
                 "把音频转成文字（macOS 26 Speech，完全离线；不需要任何 API key）。",
                 ["path": prop("string", "音频路径（wav/m4a/aiff/mp3，装了 ffmpeg 则 ogg/opus 也行）"),
                  "locale": prop("string", "语言，默认 zh-CN"),
                  "format": prop("string", "txt/json/srt，默认 json"),
                  "timeout": prop("integer", "秒，默认 300")],
                 required: ["path"], annotations: readOnly),
            // speak 是唯一会写文件面的工具：写一个新文件、不覆盖既有内容（同名由调用方决定，本项目不复用），
            // 所以 destructiveHint:false 是准确的「仅增量」语义，而不是"什么都不改"。
            tool("macai_speak", "语音合成落盘",
                 "用系统音色合成语音并落盘（离线）。返回音频文件路径。",
                 ["text": prop("string", "要合成的文本"),
                  "voice": prop("string", "音色名或 identifier，可用 macai_voices 查"),
                  "lang": prop("string", "语言，如 zh-CN；默认按文本自动取系统音色"),
                  "out": prop("string", "输出路径（扩展名决定容器 wav/m4a/caf/aiff）；留空写临时文件"),
                  "rate": prop("number", "语速 0…1，默认 0.5")],
                 required: ["text"], annotations: writesNewFile),
            tool("macai_voices", "可用音色列表",
                 "列出系统可用音色（可按语言过滤）。",
                 ["lang": prop("string", "语言前缀，如 zh / en")], required: [], annotations: readOnly),
            tool("macai_translate", "离线翻译",
                 "离线翻译（系统 Translation 框架）。需要该语言对的语言包已下载，否则返回可执行的安装指引。",
                 ["text": prop("string", "待翻译文本"),
                  "from": prop("string", "源语言，留空自动判断"),
                  "to": prop("string", "目标语言，如 zh-Hans / en")],
                 required: ["text", "to"], annotations: readOnly),
            tool("macai_nlp", "文本分析",
                 "文本分析：语种识别、分词、词性、命名实体、句子切分（NaturalLanguage，离线）。",
                 ["text": prop("string", "待分析文本")], required: ["text"], annotations: readOnly),
            tool("macai_sound", "声音分类",
                 "声音分类（SoundAnalysis 内置 300 类：笑声、掌声、警报、语音、音乐…）。",
                 ["path": prop("string", "音频路径"),
                  "top": prop("integer", "每窗口取前几类，默认 3")],
                 required: ["path"], annotations: readOnly),
            tool("macai_capabilities", "本机能力状态",
                 "查询本机各能力的可用状态（语音资产、翻译语言包是否就绪）。",
                 ["locale": prop("string", "语音资产要查的语言，默认 zh-CN")], required: [], annotations: readOnly),
        ]
    }

    /// 只读、不出网：纯本地计算，不写文件、不发请求。
    ///
    /// 为什么显式写：规范对 annotations 的默认值全是**悲观值**
    /// （readOnlyHint:false、destructiveHint:true、openWorldHint:true），
    /// 不声明就等于让客户端按"可能改数据、可能出网"处理 —— 确认框和自动执行策略都会因此变严。
    static let readOnly: [String: Any] = [
        "readOnlyHint": true,
        "openWorldHint": false,
    ]

    /// 写一个新文件、不覆盖既有内容：非只读，但既不是破坏性的也不是幂等的（同名路径重跑会重新生成）。
    static let writesNewFile: [String: Any] = [
        "readOnlyHint": false,
        "destructiveHint": false,
        "idempotentHint": false,
        "openWorldHint": false,
    ]

    static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    static func tool(_ name: String, _ title: String, _ description: String,
                     _ properties: [String: Any], required: [String],
                     annotations: [String: Any]) -> [String: Any] {
        ["name": name,
         "title": title,
         "description": description,
         "annotations": annotations,
         "inputSchema": ["type": "object", "properties": properties, "required": required]]
    }

    static func call(name: String, arguments: [String: Any]) throws -> String {
        func str(_ key: String) -> String? { arguments[key] as? String }
        func int(_ key: String, _ fallback: Int) -> Int { (arguments[key] as? NSNumber)?.intValue ?? fallback }
        func dbl(_ key: String, _ fallback: Double) -> Double { (arguments[key] as? NSNumber)?.doubleValue ?? fallback }
        func bool(_ key: String) -> Bool { (arguments[key] as? NSNumber)?.boolValue ?? (arguments[key] as? Bool) ?? false }

        switch name {
        case "macai_ocr":
            guard let path = str("path") else { throw MacAIError("缺少参数 path", code: ExitCode.usage) }
            var options = OCREngine.Options()
            if let langs = str("lang") { options.languages = langs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            options.fast = bool("fast")
            options.maxWidth = int("max_width", 2400)
            options.barcodes = bool("barcodes")
            let page = try OCREngine.recognize(path: path, options: options)
            return JSONOut.render(["ok": true, "data": OCREngine.json(page)])

        case "macai_transcribe":
            guard let path = str("path") else { throw MacAIError("缺少参数 path", code: ExitCode.usage) }
            var options = STTEngine.Options()
            options.audioPath = path
            options.locale = Support.normalizeLanguageTag(str("locale")) ?? "zh-CN"
            options.timeout = Double(int("timeout", 300))
            let result = try STTEngine.transcribe(options)
            switch (str("format") ?? "json").lowercased() {
            case "txt", "text":
                return result.text
            case "srt":
                return STTEngine.srt(result)
            default:
                return JSONOut.render(["ok": true, "data": STTEngine.json(result)])
            }

        case "macai_speak":
            guard let text = str("text"), !text.isEmpty else { throw MacAIError("缺少参数 text", code: ExitCode.usage) }
            var options = TTSEngine.Options()
            options.text = text
            options.voice = str("voice")
            options.language = Support.normalizeLanguageTag(str("lang"))
            if arguments["rate"] != nil { options.rate = dbl("rate", 0.5) }
            let format = (str("out") as NSString?)?.pathExtension.isEmpty == false
                ? (str("out")! as NSString).pathExtension.lowercased() : "wav"
            options.outputPath = str("out") ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("macai-tts-\(UUID().uuidString.prefix(8)).\(format)").path
            let result = try TTSEngine.synthesize(options)
            return JSONOut.render(["ok": true, "data": TTSEngine.json(result)])

        case "macai_voices":
            let voices = TTSEngine.voices(languagePrefix: str("lang"))
            return JSONOut.render(["ok": true, "data": ["count": voices.count, "voices": voices.map {
                ["id": $0.identifier, "name": $0.name, "language": $0.language]
            }]])

        case "macai_translate":
            guard let text = str("text"), let target = Support.normalizeLanguageTag(str("to")) else {
                throw MacAIError("缺少参数 text / to", code: ExitCode.usage)
            }
            let result = try TranslateEngine.translate(text: text, source: Support.normalizeLanguageTag(str("from")), target: target)
            return JSONOut.render(["ok": true, "data": TranslateEngine.json(result)])

        case "macai_nlp":
            guard let text = str("text") else { throw MacAIError("缺少参数 text", code: ExitCode.usage) }
            return JSONOut.render(["ok": true, "data": NLPEngine.json(NLPEngine.analyze(text))])

        case "macai_sound":
            guard let path = str("path") else { throw MacAIError("缺少参数 path", code: ExitCode.usage) }
            let top = int("top", 3)
            return JSONOut.render(["ok": true, "data": SoundEngine.json(try SoundEngine.classify(path: path, top: top), top: top)])

        case "macai_capabilities":
            let locale = Support.normalizeLanguageTag(str("locale")) ?? "zh-CN"
            let stt = try STTEngine.jsonAssetState(locale)
            let translate = try TranslateEngine.statusMatrix()
            let installed = TranslateEngine.installedHints(translate)
            return JSONOut.render(["ok": true, "data": [
                "tts": ["available": true, "voice_count": TTSEngine.voices().count],
                "stt": stt,
                "translate": ["installed_pairs": installed,
                              "installed_pair_count": installed.count,
                              "checked_pair_count": translate.count],
                "ocr": ["available": true, "language_count": OCREngine.supportedLanguages().count],
                "nlp": ["available": true],
                "sound": ["available": true],
            ]])

        default:
            throw MacAIError("未知工具: \(name)", hint: "调用 tools/list 看可用工具", code: ExitCode.usage)
        }
    }

    // MARK: - 输出

    static func respond(id: Any?, result: Any) {
        respond(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    static func respond(id: Any?, error: [String: Any]) {
        respond(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error])
    }

    static func respond(_ payload: [String: Any]) {
        FileHandle.standardOutput.write(Data((JSONOut.render(payload, pretty: false) + "\n").utf8))
    }
}
