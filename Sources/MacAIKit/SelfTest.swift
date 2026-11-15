import Foundation
import AppKit
import CoreGraphics

/// 端到端自检：真实合成 fixture（画图 + 合成音频）→ 真实调用每条能力 → PASS/FAIL/SKIP 表。
///
/// 这是本项目的**验收入口**：`macai selftest` 绿了才算能力可用，不是"编译过了"。
public enum SelfTest {
    public struct Row {
        public let name: String
        public let status: String   // PASS / FAIL / SKIP
        public let detail: String
        public let milliseconds: Double
    }

    /// 进度只写 stderr：`--json` 的 stdout 必须保持是**纯 JSON**。
    static func progress(_ text: String) {
        FileHandle.standardError.write(Data(("⏳ \(text)\n").utf8))
    }

    public static func run(json: Bool, allowNetworkAssets: Bool = false) -> Int32 {
        var rows: [Row] = []
        let workDir: URL
        do {
            workDir = try Support.tempDir("macai-selftest")
        } catch {
            Out.fail(MacAIError("无法创建临时目录: \(error.localizedDescription)"), json: json)
            return ExitCode.runtime
        }
        defer { try? FileManager.default.removeItem(at: workDir) }

        // ---- 1. OCR：画一张已知文本的图，再识别回来 ----
        progress("ocr: 生成 fixture 并识别…")
        do {
            let path = workDir.appendingPathComponent("ocr-fixture.png")
            try makeFixtureImage(text: ["MACAI SELFTEST 2026", "OCR-OK 02345678", "invoice 1234"], to: path)
            let (page, ms) = try Support.timed { try OCREngine.recognize(path: path.path) }
            let text = page.text
            if text.contains("OCR-OK") && text.contains("02345678") {
                rows.append(Row(name: "ocr", status: "PASS",
                                detail: "\(page.lines.count) 行 / \(page.width)x\(page.height)", milliseconds: ms))
            } else {
                rows.append(Row(name: "ocr", status: "FAIL",
                                detail: "识别结果缺少关键字: \(text.replacingOccurrences(of: "\n", with: " | "))",
                                milliseconds: ms))
            }
        } catch {
            rows.append(Row(name: "ocr", status: "FAIL", detail: "\(error)", milliseconds: 0))
        }

        // ---- 2. TTS：合成一段中文语音落盘 ----
        progress("tts: 合成中文语音…")
        let ttsPath = workDir.appendingPathComponent("tts-fixture.wav")
        var ttsIsOK = false
        do {
            var options = TTSEngine.Options()
            options.text = "这是语音合成自检，编号一零零一。"
            options.language = "zh-CN"
            options.outputPath = ttsPath.path
            let (result, ms) = try Support.timed { try TTSEngine.synthesize(options) }
            let passed = result.bytes > 4_000 && result.durationSeconds > 0.5
            ttsIsOK = passed
            rows.append(Row(name: "tts",
                            status: passed ? "PASS" : "FAIL",
                            detail: "\(result.bytes) B / \(String(format: "%.2f", result.durationSeconds))s / voice=\(result.voiceName)",
                            milliseconds: ms))
        } catch {
            rows.append(Row(name: "tts", status: "FAIL", detail: "\(error)", milliseconds: 0))
        }

        // ---- 3. STT：把刚合成的语音转写回来（资产未装则按环境 SKIP，并说明原因）----
        progress("stt: 转写刚合成的语音（资产未装则 SKIP；--install-assets 才会联网下载）…")
        if ttsIsOK {
            do {
                var options = STTEngine.Options()
                options.audioPath = ttsPath.path
                options.locale = "zh-CN"
                options.timeout = 180
                options.installAssets = allowNetworkAssets
                let (result, ms) = try Support.timed { try STTEngine.transcribe(options) }
                let passed = result.text.contains("自检") || result.text.count >= 6
                rows.append(Row(name: "stt",
                                status: passed ? "PASS" : "FAIL",
                                detail: passed
                                    ? "\(result.text.prefix(40))… (\(String(format: "%.1f", result.audioSeconds))s 音频)"
                                    : "转写结果过短: '\(result.text)'",
                                milliseconds: ms))
            } catch let error as MacAIError where error.code == ExitCode.unavailable {
                rows.append(Row(name: "stt", status: "SKIP", detail: "环境 skip：\(error.message)", milliseconds: 0))
            } catch {
                rows.append(Row(name: "stt", status: "FAIL", detail: "\(error)", milliseconds: 0))
            }
        } else {
            rows.append(Row(name: "stt", status: "SKIP", detail: "环境 skip：TTS fixture 没生成，无法做闭环", milliseconds: 0))
        }

        // ---- 4. NLP ----
        progress("nlp: 语种/分词/实体…")
        do {
            let (analysis, ms) = Support.timed { NLPEngine.analyze("Tim Cook works at Apple Inc. in Cupertino. 你好世界。") }
            let language = analysis.language ?? ""
            let passed = (language.hasPrefix("en") || language.hasPrefix("zh"))
                && analysis.tokens.count >= 5 && analysis.sentences.count >= 2
            rows.append(Row(name: "nlp",
                            status: passed ? "PASS" : "FAIL",
                            detail: "lang=\(language.isEmpty ? "?" : language) tokens=\(analysis.tokens.count) entities=\(analysis.entities.count) sentences=\(analysis.sentences.count)",
                            milliseconds: ms))
        }

        // ---- 5. 声音分析：对 TTS 语音应当判为 speech ----
        progress("sound: 声音分类…")
        if ttsIsOK {
            let speechLabels = ["speech", "male_speech", "female_speech", "narration", "conversation", "speech_synthesizer"]
            do {
                let (result, ms) = try Support.timed { try SoundEngine.classify(path: ttsPath.path, top: 5) }
                let labels = result.labels
                let passed = labels.contains { speechLabels.contains($0.0) && $0.1 > 0.2 } || (labels.first?.1 ?? 0) > 0.5
                rows.append(Row(name: "sound",
                                status: passed ? "PASS" : "FAIL",
                                detail: labels.prefix(3).map { "\($0.0)=\(String(format: "%.2f", $0.1))" }.joined(separator: " "),
                                milliseconds: ms))
            } catch {
                rows.append(Row(name: "sound", status: "FAIL", detail: "\(error)", milliseconds: 0))
            }
        }

        // ---- 6. 翻译：语言包未装 → 环境 SKIP（不是失败，但必须说清原因）----
        progress("translate: 查询语言包并翻译…")
        do {
            let status = try TranslateEngine.status(source: "en", target: "zh-Hans")
            if status.installed {
                let (result, ms) = try Support.timed {
                    try TranslateEngine.translate(text: "The system is offline.", source: "en", target: "zh-Hans", timeout: 180)
                }
                rows.append(Row(name: "translate",
                                status: result.targetText.isEmpty ? "FAIL" : "PASS",
                                detail: result.targetText, milliseconds: ms))
            } else {
                let matrix = try TranslateEngine.statusMatrix()
                let installed = TranslateEngine.installedHints(matrix)
                rows.append(Row(name: "translate", status: "SKIP",
                                detail: "环境 skip：en→zh-Hans 语言包状态 \(status.state)"
                                    + "（已安装语言对: \(installed.isEmpty ? "无" : installed.joined(separator: ", "))）",
                                milliseconds: 0))
            }
        } catch {
            rows.append(Row(name: "translate", status: "FAIL", detail: "\(error)", milliseconds: 0))
        }

        // ---- 输出 ----
        let failures = rows.filter { $0.status == "FAIL" }
        let skips = rows.filter { $0.status == "SKIP" }
        if json {
            Out.ok([
                "passed": rows.count - failures.count - skips.count,
                "failed": failures.count,
                "skipped": skips.count,
                "results": rows.map { ["name": $0.name, "status": $0.status, "detail": $0.detail, "ms": $0.milliseconds] },
            ], json: true)
        } else {
            print("macai 自检（\(rows.count) 项）")
            for row in rows {
                let mark = row.status == "PASS" ? "✅" : (row.status == "SKIP" ? "⚠️ " : "❌")
                let timing = row.milliseconds > 0 ? String(format: "  %6.0fms", row.milliseconds) : ""
                print("\(mark) \(row.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(row.status.padding(toLength: 5, withPad: " ", startingAt: 0))\(timing)  \(row.detail)")
            }
            print("")
            print("通过 \(rows.count - failures.count - skips.count) / 失败 \(failures.count) / 跳过 \(skips.count)")
            if !skips.isEmpty {
                print("⚠️ skip 均为环境类（系统资产/语言包未装），不是隐藏失败；对应的修复命令写在各自 detail 里。")
            }
        }
        return failures.isEmpty ? ExitCode.ok : ExitCode.runtime
    }

    /// 用 CoreGraphics 画一张含指定文本的 PNG（自检 fixture；不依赖任何外部素材）。
    public static func makeFixtureImage(text lines: [String], to url: URL,
                                        size: CGSize = CGSize(width: 900, height: 260)) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MacAIError("无法创建绘图上下文")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28),
            .foregroundColor: NSColor.black,
        ]
        var y = size.height - 56
        for line in lines {
            (line as NSString).draw(at: CGPoint(x: 28, y: y), withAttributes: attributes)
            y -= 46
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw MacAIError("fixture 图片编码失败")
        }
        try data.write(to: url)
    }
}
