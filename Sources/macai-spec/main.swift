import Foundation
import MacAIKit

// 极简单测跑者：只装 Command Line Tools 的机器上 XCTest / swift-testing 都不可用，
// 所以断言自己做。失败 → 退出码 1，可直接接进脚本与 CI。

var passed = 0
var failures: [String] = []

func check(_ condition: Bool, _ label: String, detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
    } else {
        let extra = detail()
        failures.append(extra.isEmpty ? label : "\(label) — \(extra)")
        print("❌ \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    check(lhs == rhs, label, detail: "期望 \(rhs)，实际 \(lhs)")
}

func throwsError(_ label: String, _ body: () throws -> Void) {
    do {
        try body()
        check(false, label, detail: "期望抛错，但没有抛")
    } catch {
        passed += 1
    }
}

/// 期望抛 MacAIError，且**退出码与文案都对**（帧流的错误路径全靠它断言）。
func throwsMacAI(_ label: String, contains: String, code: Int32, _ body: () throws -> Void) {
    do {
        try body()
        check(false, label, detail: "期望抛错，但没有抛")
    } catch let error as MacAIError {
        check(error.code == code && error.message.contains(contains), label,
              detail: "code=\(error.code) message=\(error.message)")
    } catch {
        check(false, label, detail: "错误类型不是 MacAIError: \(error)")
    }
}

/// 帧流夹具：`[u32 大端长度][字节]`；`specFrame` 的终止符要另外拼。
func specHeader(_ length: UInt32) -> Data {
    Data([UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
          UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
}
func specFrame(_ payload: Data) -> Data { specHeader(UInt32(payload.count)) + payload }
let specTerminator = Data([0, 0, 0, 0])

func suite(_ name: String, _ body: () -> Void) {
    print("▶︎ \(name)")
    body()
}

// MARK: - 参数解析

suite("参数解析") {
    let args = Args(["--json", "--lang", "zh-Hans,en-US", "--max-width=1200", "a.png", "b.png", "--fast"])
    check(args.bool("json"), "--json 被识别为开关")
    equal(args.list("lang"), ["zh-Hans", "en-US"], "逗号分隔列表")
    equal(args.int("max-width", default: 0), 1200, "--key=value 形式")
    check(args.bool("fast"), "尾部开关")
    equal(args.positional, ["a.png", "b.png"], "位置参数")

    // 曾经的真实坑：--barcode 未登记为布尔 → "scan.png" 被吃成它的值，图片路径消失。
    let scan = Args(["--barcode", "scan.png"])
    check(scan.bool("barcode"), "--barcode 是开关")
    equal(scan.positional, ["scan.png"], "开关不吃掉后面的位置参数")

    let lang = Args(["--lang", "zh-Hans", "img.png"])
    equal(lang.string("lang"), "zh-Hans", "未登记选项取一个值")
    equal(lang.positional, ["img.png"], "取值后剩下的才是位置参数")

    let dangling = Args(["--voice"])
    check(dangling.bool("voice"), "缺值的长选项退化为开关")
    check(dangling.positional.isEmpty, "缺值选项不产生位置参数")
}

// MARK: - 输出与工具

suite("输出与工具") {
    equal(Support.srtTimestamp(0), "00:00:00,000", "SRT 零点")
    equal(Support.srtTimestamp(3661.5), "01:01:01,500", "SRT 跨小时")
    equal(Support.srtTimestamp(-3), "00:00:00,000", "SRT 负值夹紧")
    equal(Support.normalizeLanguageTag("zh"), "zh-Hans", "zh 归一")
    equal(Support.normalizeLanguageTag("zh-CN"), "zh-Hans", "zh-CN 归一")
    equal(Support.normalizeLanguageTag("en"), "en-US", "en 归一")
    equal(Support.normalizeLanguageTag("de"), "de", "未知标签原样")
    check(Support.normalizeLanguageTag("auto") == nil, "auto 表示不限定")
    check(Support.normalizeLanguageTag("   ") == nil, "空白表示不限定")

    let json = JSONOut.render(["a": Double.nan, "b": [Double.infinity, 1.5]])
    check(!json.contains("nan") && !json.contains("inf"), "非有限浮点被净化", detail: json)
    check(json.contains("null"), "非法数值落成 null")
    check(JSONOut.parse(json) != nil, "净化后仍是合法 JSON")
    equal(JSONOut.render(["z": 1, "a": 2]), JSONOut.render(["a": 2, "z": 1]), "JSON 键有序（输出可断言）")
}

// MARK: - 错误信封（MCP 与 CLI 共用一套）

suite("错误信封") {
    // 形状：{ok, code, message, retryable, remediation}。
    // 区别仅在 message：CLI 的历史字段叫 error（已有断言与脚本依赖），这里同时给 message。
    func envelope(_ code: Int32) -> [String: Any] {
        JSONOut.errorPayload(MacAIError("boom", hint: "怎么修", code: code))
    }
    equal(envelope(3)["ok"] as? Bool, false, "失败信封 ok=false")
    equal(envelope(3)["code"] as? Int, 3, "code 是数字（脚本可直接判等）")
    equal(envelope(3)["message"] as? String, "boom", "message 字段")
    equal(envelope(3)["error"] as? String, "boom", "error 是 message 的兼容别名")
    equal(envelope(3)["remediation"] as? String, "怎么修", "remediation 字段")
    equal(envelope(3)["hint"] as? String, "怎么修", "hint 是 remediation 的兼容别名")

    // retryable 是这一版新增的决策字段：能力不可用与参数错重试无意义，运行失败多半可重试。
    equal(envelope(ExitCode.unavailable)["retryable"] as? Bool, false, "能力不可用（3）→ retryable=false")
    equal(envelope(ExitCode.usage)["retryable"] as? Bool, false, "参数错（1）→ retryable=false")
    equal(envelope(ExitCode.runtime)["retryable"] as? Bool, true, "运行失败（2）→ retryable=true")
    // 未知码不能默认成「可重试」：那会让调用方对真正的硬错误反复重试。
    equal(envelope(99)["retryable"] as? Bool, false, "未知退出码 → retryable=false（保守）")
    // 没有 hint 时不留空串字段，免得调用方把 "" 当成「有指引」。
    let bare = JSONOut.errorPayload(MacAIError("bare"))
    check(bare["remediation"] == nil && bare["hint"] == nil, "没有 hint 时不产出空的 remediation/hint")
}

// MARK: - MCP 协议

suite("MCP 协议") {
    // lifecycle：支持请求的版本才回请求值，否则 MUST 回自己支持的版本 —— 绝不回显。
    equal(MCPServer.negotiateProtocolVersion("2024-11-05"), "2024-11-05", "协商：命中旧版本原样回")
    equal(MCPServer.negotiateProtocolVersion("2025-06-18"), "2025-06-18", "协商：命中最新版本原样回")
    equal(MCPServer.negotiateProtocolVersion("1999-01-01"),
          MCPServer.supportedProtocolVersions[0], "协商：未知版本回支持列表里最新的")
    equal(MCPServer.negotiateProtocolVersion(nil),
          MCPServer.supportedProtocolVersions[0], "协商：没给版本也回最新的")
    check(!MCPServer.supportedProtocolVersions.contains("2025-11-25"), "未实现的 2025-11-25 不在支持列表里")
    check(MCPServer.supportedProtocolVersions.count >= 2, "至少声明两个版本（要能回落）")

    // instructions 的长度上限：Claude Code 4096 字符截断；部分客户端 32 KB 超限断连。
    let bytes = MCPServer.instructions.utf8.count
    check(bytes < 2048, "instructions 在 2 KB 以内", detail: "\(bytes) 字节 / \(MCPServer.instructions.count) 字符")

    // 工具元数据：title 与 annotations 是客户端真实消费的字段，漏一个就等于让客户端按悲观默认值处理。
    for tool in MCPServer.tools {
        let name = tool["name"] as? String ?? "?"
        let title = tool["title"] as? String ?? ""
        check(!title.isEmpty, "\(name) 有 title")
        guard let annotations = tool["annotations"] as? [String: Any] else {
            check(false, "\(name) 有 annotations"); continue
        }
        equal(annotations["openWorldHint"] as? Bool, false, "\(name) 不出网")
        if name == "macai_speak" {
            equal(annotations["readOnlyHint"] as? Bool, false, "macai_speak 不是只读（它写文件）")
            equal(annotations["destructiveHint"] as? Bool, false, "macai_speak 不破坏既有内容")
        } else {
            equal(annotations["readOnlyHint"] as? Bool, true, "\(name) 只读")
        }
    }
}

// MARK: - NLP

suite("NLP") {
    let english = NLPEngine.analyze("Tim Cook works at Apple Inc. in Cupertino.")
    check(english.tokens.count >= 4, "普通句子必须分得出词（曾经用错 scheme 导致 tokens 全空）",
          detail: "tokens=\(english.tokens.count)")
    equal(NLPEngine.detectLanguage("这是一个中文句子，用来测试语种识别。").0, "zh-Hans", "中文语种识别")
    check((NLPEngine.detectLanguage("This is an English sentence.").0 ?? "").hasPrefix("en"), "英文语种识别")
    check(NLPEngine.analyze("First sentence. Second sentence!").sentences.count >= 2, "句子切分")
    check(!english.entities.contains { $0.hasSuffix("=OtherWord") }, "实体白名单不混入 OtherWord",
          detail: english.entities.joined(separator: ", "))
    check(english.entities.contains { $0.contains("PersonalName") || $0.contains("PlaceName") },
          "至少识别出人名或地名", detail: english.entities.joined(separator: ", "))
}

// MARK: - STT 文本规范化

suite("STT 文本规范化") {
    equal(STTEngine.normalizeTranscript("你好 ，这是测试 。"), "你好，这是测试。", "清中文标点两侧空格")
    equal(STTEngine.normalizeTranscript("今天是 10月 7号。"), "今天是10月7号。", "清数字单位两侧空格")
    equal(STTEngine.normalizeTranscript("编号 1001。"), "编号1001。", "中文与数字之间粘连")
    equal(STTEngine.normalizeTranscript("hello world 你好"), "hello world 你好", "英文词间/英中之间的空格保留")
    equal(STTEngine.normalizeTranscript("  你好  "), "你好", "裁掉首尾空白")
}

// MARK: - OCR stdin 入口

suite("OCR stdin 入口") {
    // ① 空输入：stdin 读来的 0 字节必须在**建源之前**就报错（给得出可执行的修复命令）
    throwsError("空 stdin 数据直接抛错") {
        _ = try OCREngine.loadImage(stdin: Data(), maxWidth: 2400)
    }
    do {
        _ = try OCREngine.loadImage(stdin: Data(), maxWidth: 2400)
        check(false, "空 stdin 的错误带退出码语义 1")
    } catch let error as MacAIError {
        equal(error.code, ExitCode.usage, "空 stdin 的错误带退出码语义 1")
    } catch {
        check(false, "空 stdin 的错误类型是 MacAIError", detail: "\(error)")
    }

    // ② 垃圾字节：ImageIO 的 data 源是惰性的（建源成功、取图才失败），
    //    对调用方来说必须是「无法解析图片」= 运行失败码 2，不能漏成崩溃或空结果。
    let garbage = Data("not an image".utf8)
    throwsError("非图片字节直接抛错") {
        _ = try OCREngine.loadImage(stdin: garbage, maxWidth: 2400)
    }
    do {
        _ = try OCREngine.loadImage(stdin: garbage, maxWidth: 2400)
        check(false, "非图片字节的错误带退出码语义 2")
    } catch let error as MacAIError {
        equal(error.code, ExitCode.runtime, "非图片字节的错误带退出码语义 2")
    } catch {
        check(false, "非图片字节的错误类型是 MacAIError", detail: "\(error)")
    }
    throwsError("垃圾字节走完整 recognize(stdinData:) 同样抛错") {
        _ = try OCREngine.recognize(stdinData: garbage)
    }

    // ③ 同一张图，stdin 与文件路径必须等值：现造一张含已知文字的图，
    //    分别走两条入口，比对尺寸/降采样标志/每一行（text + confidence + box）。
    do {
        let dir = try Support.tempDir("macai-spec-ocr")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = dir.appendingPathComponent("stdin-equivalence.png")
        try SelfTest.makeFixtureImage(text: ["MACAI STDIN EQUIVALENCE 2026", "OCR-OK 1234"], to: fixture)
        let bytes = try Data(contentsOf: fixture)

        // 无降采样（默认 maxWidth 2400 > 900）：走的是 CGImageSourceCreateImageAtIndex 分支
        var plain = OCREngine.Options()
        plain.languages = ["en-US"]
        let fromPath = try OCREngine.recognize(path: fixture.path, options: plain)
        let fromStdin = try OCREngine.recognize(stdinData: bytes, options: plain)

        check(fromPath.lines.count >= 2, "路径入口识别出 fixture 的两行已知文字",
              detail: "lines=\(fromPath.lines.count) text=\(fromPath.text)")
        check(fromStdin.lines.count >= 2, "stdin 入口识别出 fixture 的两行已知文字",
              detail: "lines=\(fromStdin.lines.count) text=\(fromStdin.text)")

        equal(fromStdin.width, fromPath.width, "stdin 与路径宽度相等")
        equal(fromStdin.height, fromPath.height, "stdin 与路径高度相等")
        equal(fromStdin.scaled, fromPath.scaled, "stdin 与路径降采样标志相等")
        equal(fromStdin.lines.count, fromPath.lines.count, "stdin 与路径行数相等")
        equal(fromStdin.lines, fromPath.lines, "stdin 与路径逐行相等（text/confidence/box）")
        equal(fromStdin.text, fromPath.text, "stdin 与路径整体文本相等")
        equal(fromPath.file, fixture.path, "路径入口如实记 file")
        equal(fromStdin.file, "<stdin>", "stdin 入口记 <stdin>（不落盘、不冒充路径）")

        // loadImage 两侧的尺寸元组同样要相等（CLI 与 MCP 都吃这层）
        let (_, pathWidth, pathHeight, pathScaled) = try OCREngine.loadImage(path: fixture.path, maxWidth: 2400)
        let (_, stdinWidth, stdinHeight, stdinScaled) = try OCREngine.loadImage(stdin: bytes, maxWidth: 2400)
        check([pathWidth, pathHeight, pathScaled ? 1 : 0] == [stdinWidth, stdinHeight, stdinScaled ? 1 : 0],
              "loadImage 两条入口的 (width,height,scaled) 相等",
              detail: "path=\(pathWidth)x\(pathHeight)/\(pathScaled) stdin=\(stdinWidth)x\(stdinHeight)/\(stdinScaled)")

        // 降采样分支（maxWidth 400 < 900）：两条入口也必须给出同样的图与同样的像素框
        var downscale = OCREngine.Options()
        downscale.languages = ["en-US"]
        downscale.maxWidth = 400
        let smallPath = try OCREngine.recognize(path: fixture.path, options: downscale)
        let smallStdin = try OCREngine.recognize(stdinData: bytes, options: downscale)
        check(smallPath.scaled && smallStdin.scaled, "maxWidth 400 时两侧都走降采样",
              detail: "path=\(smallPath.scaled) stdin=\(smallStdin.scaled)")
        equal(smallStdin.width, smallPath.width, "降采样后 stdin 与路径宽度相等")
        equal(smallStdin.height, smallPath.height, "降采样后 stdin 与路径高度相等")
        equal(smallStdin.lines, smallPath.lines, "降采样后 stdin 与路径逐行相等")
        check(smallPath.lines.allSatisfy { $0.box.count == 4 }, "降采样后每行仍有 4 元像素框")
    } catch {
        check(false, "OCR stdin 等值 fixture 能生成并识别", detail: "\(error)")
    }
}

// MARK: - OCR 帧流（`macai ocr - --frames`）

suite("OCR 帧流（stdin 多图）") {
    let first = Data([0x89, 0x50, 0x4e, 0x47, 0x01, 0x02])
    let second = Data(repeating: 0xAB, count: 300)

    // ① 正常流：两帧 + 零终止符，解析出的字节逐元素相等
    do {
        let frames = try FrameStream.parse(specFrame(first) + specFrame(second) + specTerminator)
        equal(frames.count, 2, "正常帧流解析出 2 帧")
        equal(frames[0], first, "第 1 帧字节逐元素相等")
        equal(frames[1], second, "第 2 帧字节逐元素相等")
    } catch {
        check(false, "正常帧流应解析成功", detail: "\(error)")
    }

    // ② EOF 也可正常结束（管道天然如此：不给终止符不算错）
    equal((try? FrameStream.parse(specFrame(first) + specFrame(second)))?.count, 2,
          "EOF 结束（无终止符）同样解析出 2 帧")
    // ③ 零终止符：长度 0 是终止符而不是空帧；单独一个终止符 / 空数据 = 空流（CLI 报「stdin 是空的」）
    equal((try? FrameStream.parse(specTerminator)) ?? [Data([9])], [], "单独终止符 = 空流（0 不是空帧）")
    equal((try? FrameStream.parse(Data())) ?? [Data([9])], [], "空数据 = 空流")
    // ④ 终止符之后不得再有字节（不允许静默忽略）
    throwsMacAI("终止符之后还有字节 → 报错", contains: "终止符", code: ExitCode.runtime) {
        _ = try FrameStream.parse(specFrame(first) + specTerminator + Data([0x00]))
    }

    // ⑤ 截断：声明的长度 > 剩余字节（帧体），以及长度前缀本身不完整
    throwsMacAI("帧体被截断（声明 100 只有 5）→ 运行失败 2", contains: "第 1 帧被截断", code: ExitCode.runtime) {
        _ = try FrameStream.parse(specHeader(100) + Data(repeating: 1, count: 5))
    }
    throwsMacAI("尾部只剩 2 字节长度前缀 → 截断", contains: "帧流被截断", code: ExitCode.runtime) {
        _ = try FrameStream.parse(specFrame(first) + Data([0x00, 0x00]))
    }

    // ⑥ 上限：默认值就是文档值；超限必须报错（而不是继续分配/静默截断）
    equal(FrameStream.limits.maxFrameBytes, 64 * 1024 * 1024, "默认单帧上限 = 64 MiB")
    equal(FrameStream.limits.maxFrames, 64, "默认帧数上限 = 64")
    equal(FrameStream.limits.maxTotalBytes, 256 * 1024 * 1024, "默认总量上限 = 256 MiB")
    // 声明 4 GiB：**在读它的字节之前**就该被拒（先校验再分配，不能按来路不明的长度分配内存）
    throwsMacAI("单帧声明 4 GiB → 单帧上限报错（未分配）", contains: "超过单帧上限", code: ExitCode.runtime) {
        _ = try FrameStream.parse(specHeader(0xFFFF_FFFF))
    }
    let small = FrameStream.Limits(maxFrameBytes: 1024, maxFrames: 2, maxTotalBytes: 4096)
    throwsMacAI("帧数超限 → 报错", contains: "帧数超过上限", code: ExitCode.runtime) {
        _ = try FrameStream.parse(specFrame(Data([1])) + specFrame(Data([2])) + specFrame(Data([3])), limits: small)
    }
    equal((try? FrameStream.parse(specFrame(Data([1])) + specFrame(Data([2])), limits: small))?.count, 2,
          "帧数正好到上限仍然可以")
    throwsMacAI("单帧超过自定义上限 → 报错", contains: "超过单帧上限", code: ExitCode.runtime) {
        _ = try FrameStream.parse(specFrame(Data(repeating: 1, count: 2048)), limits: small)
    }
    let tiny = FrameStream.Limits(maxFrameBytes: 1024, maxFrames: 64, maxTotalBytes: 1500)
    throwsMacAI("总量超限 → 报错", contains: "总量超过上限", code: ExitCode.runtime) {
        _ = try FrameStream.parse(specFrame(Data(repeating: 1, count: 1024)) + specFrame(Data(repeating: 2, count: 1024)),
                                  limits: tiny)
    }

    // ⑦ 帧流识别与多路径识别**逐元素相等**（验收 5 的自动化断言：pages / lines 的 text·box·confidence）
    do {
        let dir = try Support.tempDir("macai-spec-frames")
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstPath = dir.appendingPathComponent("frame-1.png")
        let secondPath = dir.appendingPathComponent("frame-2.png")
        try SelfTest.makeFixtureImage(text: ["MACAI FRAME STREAM ONE", "ALPHA 1111"], to: firstPath)
        try SelfTest.makeFixtureImage(text: ["MACAI FRAME STREAM TWO", "BRAVO 2222"], to: secondPath)
        let firstBytes = try Data(contentsOf: firstPath)
        let secondBytes = try Data(contentsOf: secondPath)

        var options = OCREngine.Options()
        options.languages = ["en-US"]
        let frames = try FrameStream.parse(specFrame(firstBytes) + specFrame(secondBytes) + specTerminator)
        equal(frames.count, 2, "真实图片帧流解析出 2 帧")

        let viaFrames = try frames.enumerated().map { try OCREngine.recognize(frame: $0.element, index: $0.offset + 1, options: options) }
        let viaPaths = [try OCREngine.recognize(path: firstPath.path, options: options),
                        try OCREngine.recognize(path: secondPath.path, options: options)]

        check(viaPaths[0].lines.count >= 2, "第 1 张 fixture 识别出已知文字", detail: viaPaths[0].text)
        check(viaPaths[1].lines.count >= 2, "第 2 张 fixture 识别出已知文字", detail: viaPaths[1].text)
        equal(viaFrames.map(\.lines), viaPaths.map(\.lines), "帧流与多路径逐行相等（text/confidence/box）")
        equal(viaFrames.map(\.text), viaPaths.map(\.text), "帧流与多路径整体文本相等")
        equal(viaFrames.map { [$0.width, $0.height, $0.scaled ? 1 : 0] },
              viaPaths.map { [$0.width, $0.height, $0.scaled ? 1 : 0] }, "帧流与多路径尺寸/降采样标志相等")
        equal(viaFrames.map(\.file), ["<stdin>#1", "<stdin>#2"], "每帧的 file 记 <stdin>#N（不落盘、不冒充路径）")

        // ⑧ 某帧不是图片：必须点名**第几帧** + 退出码 2
        let badFrames = try FrameStream.parse(specFrame(firstBytes) + specFrame(Data("not an image".utf8)) + specTerminator)
        throwsMacAI("第 2 帧不是图片 → 点名帧号 + 运行失败 2", contains: "第 2 帧", code: ExitCode.runtime) {
            _ = try OCREngine.recognize(frame: badFrames[1], index: 2, options: options)
        }
    } catch {
        check(false, "帧流等值 fixture 能生成并识别", detail: "\(error)")
    }
}

// MARK: - 声音分析参数

suite("声音分析参数") {
    throwsMacAI("负 top 走参数错误而不是崩进程", contains: "top", code: ExitCode.usage) {
        _ = try SoundEngine.classify(path: "/nonexistent.wav", top: -1)
    }
    throwsMacAI("top=0 同样拒绝", contains: "top", code: ExitCode.usage) {
        _ = try SoundEngine.classify(path: "/nonexistent.wav", top: 0)
    }
}

// MARK: - TTS 参数

suite("TTS 参数") {
    let tmp = FileManager.default.temporaryDirectory
    throwsError("空文本直接失败") {
        var options = TTSEngine.Options()
        options.outputPath = tmp.appendingPathComponent("spec-x.wav").path
        _ = try TTSEngine.synthesize(options)
    }
    throwsError("缺输出路径直接失败") {
        var options = TTSEngine.Options()
        options.text = "hello"
        _ = try TTSEngine.synthesize(options)
    }
    throwsError("未知音色给错误而不是静默用默认音色") {
        var options = TTSEngine.Options()
        options.text = "hello"
        options.voice = "definitely-not-a-voice"
        options.outputPath = tmp.appendingPathComponent("spec-y-\(UUID().uuidString).wav").path
        _ = try TTSEngine.synthesize(options)
    }

    // 输出路径是用户数据边界：既不能覆盖文件，也不能把目录替换成音频。
    let existingFile = tmp.appendingPathComponent("spec-existing-\(UUID().uuidString).wav")
    try? Data("keep".utf8).write(to: existingFile)
    throwsMacAI("输出文件已存在时拒绝覆盖", contains: "拒绝覆盖", code: ExitCode.usage) {
        var options = TTSEngine.Options()
        options.text = "hello"
        options.outputPath = existingFile.path
        _ = try TTSEngine.synthesize(options)
    }
    equal(try? String(contentsOf: existingFile, encoding: .utf8), "keep", "拒绝覆盖时原文件内容未变")

    let existingDir = tmp.appendingPathComponent("spec-existing-dir-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)
    throwsMacAI("输出路径是目录时拒绝写入", contains: "目录", code: ExitCode.usage) {
        var options = TTSEngine.Options()
        options.text = "hello"
        options.outputPath = existingDir.path
        _ = try TTSEngine.synthesize(options)
    }
    var isDir: ObjCBool = false
    check(FileManager.default.fileExists(atPath: existingDir.path, isDirectory: &isDir) && isDir.boolValue,
          "拒绝写入后目录仍在")

    check(TTSEngine.voices(languagePrefix: "zh").count > 0, "系统自带中文音色可用")

    // 音色元数据：gender/novelty 必须拿得到（选音色全靠它，光看名字选不出来）
    let zhFemale = TTSEngine.voices(languagePrefix: "zh", gender: "female")
    check(!zhFemale.isEmpty, "中文女声音色可枚举", detail: "\(zhFemale.count) 个")
    check(zhFemale.allSatisfy { $0.gender == "female" && $0.language.hasPrefix("zh") }, "--gender 过滤生效")
    // novelty 标记本身要能透出来（系统里只有部分趣味音色带这个标记；
    // ⚠️ 实测中文的 eloquence 老式音色**没有**该标记，选音色时不能只靠它过滤）
    check(TTSEngine.voices().contains { $0.novelty }, "novelty 标记能透出（全量音色里存在）")
    check(TTSEngine.voices().contains { $0.gender == "unspecified" }, "gender 未标注也能如实列出")

    // 不给 --voice/--lang 时按文本语种自动选音色：中文必须落到中文音色，
    // 否则会被系统默认（往往是英文）音色读成拼音，且没有任何报错。
    var zhOptions = TTSEngine.Options()
    zhOptions.text = "这是中文语音合成的音色自动选择测试。"
    zhOptions.outputPath = tmp.appendingPathComponent("spec-zh-\(UUID().uuidString).wav").path
    if let zh = try? TTSEngine.synthesize(zhOptions) {
        check(zh.voiceIdentifier.lowercased().contains("zh"), "中文文本自动选到中文音色",
              detail: "voice=\(zh.voiceIdentifier)")
    } else {
        check(false, "中文文本自动选音色并合成成功")
    }
    // 自动选音色必须**确定**：中文音色全是 Q1，只比 quality 会退化成看数组顺序（可能挑到 eloquence 机械音）
    for _ in 0..<5 {
        var probe = TTSEngine.Options()
        probe.text = "中文自动选音色稳定性测试。"
        probe.outputPath = tmp.appendingPathComponent("spec-auto-\(UUID().uuidString).wav").path
        if let picked = try? TTSEngine.synthesize(probe) {
            check(!picked.voiceIdentifier.contains("eloquence") && !picked.voiceIdentifier.contains("speech.synthesis.voice"),
                  "自动选音色不会挑老式合成音", detail: picked.voiceIdentifier)
        }
    }

    var enOptions = TTSEngine.Options()
    enOptions.text = "This is an English voice auto-selection test."
    enOptions.outputPath = tmp.appendingPathComponent("spec-en-\(UUID().uuidString).wav").path
    if let en = try? TTSEngine.synthesize(enOptions) {
        check(en.voiceIdentifier.lowercased().contains("en"), "英文文本自动选到英文音色",
              detail: "voice=\(en.voiceIdentifier)")
    } else {
        check(false, "英文文本自动选音色并合成成功")
    }
}

// MARK: - 汇总

print("")
if failures.isEmpty {
    print("✅ spec 全绿：\(passed) 项断言")
    exit(ExitCode.ok)
} else {
    print("❌ spec 失败 \(failures.count) 项（通过 \(passed) 项）：")
    for failure in failures { print("   - \(failure)") }
    exit(ExitCode.runtime)
}
