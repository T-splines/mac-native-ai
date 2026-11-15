import Foundation
import AVFoundation

/// 系统语音合成（AVSpeechSynthesizer），落盘为音频文件。
///
/// ⚠️ 坑（必读）：`write(_:toBufferCallback:)` 在**没有泵 runloop** 的 CLI 里
/// 一个回调都不会触发 —— 表现为"合成成功但文件 0 字节"。这里必须 `RunLoop.main.run(until:)`
/// 循环推进，直到 delegate 报告结束（且缓冲区已静默）才收尾。
public enum TTSEngine {
    public struct Voice {
        public let identifier: String
        public let name: String
        public let language: String
        public let quality: Int
        /// "female" / "male" / "unspecified"（系统给的元数据，`AVSpeechSynthesisVoice.gender`）
        public let gender: String
        /// novelty = 系统的趣味/老式音色（`eloquence`、`Bells`、`Boing` 之类），不适合当默认朗读音
        public let novelty: Bool
    }

    public struct Options {
        public var text: String = ""
        public var voice: String? = nil
        public var language: String? = nil
        public var rate: Double? = nil
        public var pitch: Double? = nil
        public var volume: Double? = nil
        public var outputPath: String = ""
        public var format: String? = nil
        public var engine: String = "av"
        public init() {}
    }

    public struct Result {
        public let path: String
        public let bytes: Int64
        public let milliseconds: Double
        public let voiceIdentifier: String
        public let voiceName: String
        public let sampleRate: Double
        public let durationSeconds: Double
        public let engine: String
    }

    public static let supportedFormats: Set<String> = ["wav", "aiff", "aif", "m4a", "caf"]

    public static func voices(languagePrefix: String? = nil, gender: String? = nil) -> [Voice] {
        var list = AVSpeechSynthesisVoice.speechVoices().map { voice -> Voice in
            let genderName: String
            switch voice.gender {
            case .male: genderName = "male"
            case .female: genderName = "female"
            default: genderName = "unspecified"
            }
            return Voice(identifier: voice.identifier, name: voice.name, language: voice.language,
                         quality: Int(voice.quality.rawValue), gender: genderName,
                         novelty: voice.voiceTraits.contains(.isNoveltyVoice))
        }
        if let prefix = languagePrefix?.lowercased(), !prefix.isEmpty {
            list = list.filter { $0.language.lowercased().hasPrefix(prefix) }
        }
        if let wanted = gender?.lowercased(), !wanted.isEmpty, wanted != "any" {
            list = list.filter { $0.gender.lowercased() == wanted }
        }
        return list.sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }

    private static func resolveVoice(_ options: Options) throws -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        if let wanted = options.voice?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
            let lowered = wanted.lowercased()
            if let exact = all.first(where: { $0.identifier.lowercased() == lowered || $0.name.lowercased() == lowered }) {
                return exact
            }
            // 允许 `--lang` 限定下的模糊匹配，避免"名字对不上就静默用默认音色"。
            if let language = options.language?.lowercased(),
               let partial = all.first(where: { $0.language.lowercased().hasPrefix(language) && $0.name.lowercased().contains(lowered) }) {
                return partial
            }
            throw MacAIError("找不到音色 '\(wanted)'",
                             hint: "用 `macai voices --lang zh` 列出可用音色（identifier 或 name 都可以传）")
        }
        if let language = options.language, !language.isEmpty {
            if let best = bestVoice(for: language, among: all) { return best }
            throw MacAIError("系统没有 \(language) 的音色",
                             hint: "系统设置 → 辅助功能 → 朗读内容 → 系统声音 可下载更多音色")
        }
        // 既没给音色也没给语言：按文本自身语种挑音色。
        // 否则中文文本会被系统默认音色（往往是英文）读成拼音 —— 静默的错误输出比报错更难发现。
        if let detected = NLPEngine.detectLanguage(options.text).0, !detected.isEmpty,
           let best = bestVoice(for: detected, among: all) {
            return best
        }
        return nil
    }

    static func bestVoice(for language: String, among all: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let lowered = language.lowercased()
        let exact = all.filter { $0.language.lowercased() == lowered }
        let prefix = lowered.split(separator: "-").first.map(String.init) ?? lowered
        let candidates = exact.isEmpty ? all.filter { $0.language.lowercased().hasPrefix(prefix) } : exact
        return candidates.max { rank($0) < rank($1) }
    }

    /// 自动选音色时的排序权重。
    ///
    /// ⚠️ 为什么不只比 quality：本机中文音色**全是 Q1**（Tingting 与一堆 `eloquence` 老式合成音同为 Q1），
    /// 只按 quality 取最大会退化成"看 `speechVoices()` 的数组顺序"——那是不确定的，可能挑到机械音。
    /// 所以显式排序：音质 > 现代音色（`com.apple.voice.*`，排除 `eloquence`/`speech.synthesis` 老式音） > 女声。
    /// 调用方给 `--voice` / `--lang` 时这条规则不参与。
    static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = Int(voice.quality.rawValue) * 1_000
        let identifier = voice.identifier.lowercased()
        let isLegacy = identifier.contains(".eloquence.") || identifier.contains(".speech.synthesis.voice.")
        if !isLegacy { score += 100 }
        if voice.gender == .female { score += 10 }
        return score
    }

    public static func synthesize(_ options: Options) throws -> Result {
        let text = options.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MacAIError("没有待合成的文本", hint: "传 --text \"…\" 或 --input <文本文件>")
        }
        guard !options.outputPath.isEmpty else {
            throw MacAIError("缺少输出路径", hint: "传 --out <文件>；扩展名决定容器（wav/aiff/m4a/caf）")
        }
        // Never overwrite a file the caller did not create, and never replace a directory.
        // Checking before synthesis also avoids paying the TTS cost for a doomed write.
        let target = try Support.expand(options.outputPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                throw MacAIError("输出路径是一个已存在的目录，拒绝写入: \(target)",
                                 hint: "换一个新的 --out 路径；macai 不会删除或替换目录",
                                 code: ExitCode.usage)
            }
            throw MacAIError("输出文件已存在，拒绝覆盖: \(target)",
                             hint: "换一个新的 --out 路径，或先自行移走该文件",
                             code: ExitCode.usage)
        }

        switch options.engine.lowercased() {
        case "say":
            return try synthesizeWithSay(options, text: text)
        case "av", "avspeech", "system":
            return try synthesizeWithAVSpeech(options, text: text)
        default:
            throw MacAIError("未知的 TTS 引擎 '\(options.engine)'", hint: "可选 av（默认）或 say")
        }
    }

    // MARK: - AVSpeechSynthesizer（默认）

    private static func synthesizeWithAVSpeech(_ options: Options, text: String) throws -> Result {
        let voice = try resolveVoice(options)
        let workDir = try Support.tempDir("macai-tts")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let nativeURL = workDir.appendingPathComponent("native.caf")

        let synthesizer = AVSpeechSynthesizer()
        let delegate = SynthDelegate()
        synthesizer.delegate = delegate

        let utterance = AVSpeechUtterance(string: text)
        if let voice { utterance.voice = voice }
        if let rate = options.rate { utterance.rate = Float(min(max(rate, 0), 1)) }
        if let pitch = options.pitch { utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2.0)) }
        if let volume = options.volume { utterance.volume = Float(min(max(volume, 0), 1)) }

        var writer: AVAudioFile?
        var frames: AVAudioFramePosition = 0
        var writeError: Error?
        let start = DispatchTime.now()

        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            do {
                if writer == nil {
                    writer = try AVAudioFile(forWriting: nativeURL, settings: pcm.format.settings)
                }
                try writer?.write(from: pcm)
                frames += AVAudioFramePosition(pcm.frameLength)
            } catch {
                writeError = error
            }
        }

        // 泵 runloop：不泵 = 回调永不触发。
        let timeout = max(20.0, Double(text.count) * 0.35 + 10.0)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let writeError { throw MacAIError("写入音频失败: \(writeError.localizedDescription)") }
            if delegate.finished && !synthesizer.isSpeaking { break }
        }
        // 收尾：给最后几个缓冲区一点时间落盘。
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        writer = nil

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        guard frames > 0, FileManager.default.fileExists(atPath: nativeURL.path) else {
            throw MacAIError("合成没有产出音频（0 帧）",
                             hint: "音色不可用时会出现这种结果；先用 `macai voices --lang <语言>` 确认音色存在")
        }
        let target = try Support.expand(options.outputPath)
        let source = try readAudioFormat(nativeURL.path)
        try convert(nativeURL.path, to: target, source: source, explicitFormat: options.format)

        return Result(path: target,
                      bytes: Support.fileSize(target),
                      milliseconds: elapsed,
                      voiceIdentifier: voice?.identifier ?? "system-default",
                      voiceName: voice?.name ?? "system-default",
                      sampleRate: source.sampleRate,
                      durationSeconds: source.duration,
                      engine: "av")
    }

    // MARK: - /usr/bin/say（兜底）

    private static func synthesizeWithSay(_ options: Options, text: String) throws -> Result {
        guard let say = Proc.which("say") else {
            throw MacAIError("找不到 /usr/bin/say")
        }
        let voice = try resolveVoice(options)
        let workDir = try Support.tempDir("macai-say")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let nativeURL = workDir.appendingPathComponent("native.aiff")

        var arguments: [String] = ["-o", nativeURL.path]
        if let voice { arguments.append(contentsOf: ["-v", voice.name]) }
        if let rate = options.rate {
            // say 的 -r 是每分钟词数；把 0…1 的语速映射到 90…360 wpm（0.5 居中 ≈ 180）。
            arguments.append(contentsOf: ["-r", String(Int(90 + rate * 270))])
        }
        arguments.append(text)

        let start = DispatchTime.now()
        let result = try Proc.run(say, arguments, timeout: 120)
        guard result.ok, FileManager.default.fileExists(atPath: nativeURL.path) else {
            throw MacAIError("say 合成失败（退出码 \(result.status)）: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let target = try Support.expand(options.outputPath)
        let source = try readAudioFormat(nativeURL.path)
        try convert(nativeURL.path, to: target, source: source, explicitFormat: options.format)

        return Result(path: target,
                      bytes: Support.fileSize(target),
                      milliseconds: elapsed,
                      voiceIdentifier: voice?.identifier ?? "system-default",
                      voiceName: voice?.name ?? "system-default",
                      sampleRate: source.sampleRate,
                      durationSeconds: source.duration,
                      engine: "say")
    }

    // MARK: - 容器转换（afconvert，系统自带）

    struct SourceFormat {
        let sampleRate: Double
        let channels: Int
        let duration: Double
    }

    static func readAudioFormat(_ path: String) throws -> SourceFormat {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            throw MacAIError("无法读取音频文件: \(path)")
        }
        let rate = file.fileFormat.sampleRate
        let frames = Double(file.length)
        return SourceFormat(sampleRate: rate, channels: Int(file.fileFormat.channelCount),
                            duration: rate > 0 ? frames / rate : 0)
    }

    static func convert(_ inputPath: String, to outputPath: String, source: SourceFormat, explicitFormat: String?) throws {
        let ext = (explicitFormat ?? (outputPath as NSString).pathExtension).lowercased()
        let resolved = ext.isEmpty ? "wav" : ext
        guard supportedFormats.contains(resolved) else {
            throw MacAIError("不支持的音频格式 '.\(resolved)'", hint: "支持: \(supportedFormats.sorted().joined(separator: ", "))")
        }
        let rate = Int(source.sampleRate.rounded())
        // 已经是目标容器且是原生 CAF 直通（避免无谓转换）
        if (inputPath as NSString).pathExtension.lowercased() == resolved {
            if inputPath == outputPath { return }
            try FileManager.default.copyItem(atPath: inputPath, toPath: outputPath)
            return
        }
        guard let afconvert = Proc.which("afconvert", extraDirs: ["/usr/bin"]) else {
            throw MacAIError("找不到 /usr/bin/afconvert，无法转换音频容器")
        }
        var arguments: [String] = []
        switch resolved {
        case "wav": arguments = ["-f", "WAVE", "-d", "LEI16@\(rate)", "-c", String(source.channels)]
        case "aiff", "aif": arguments = ["-f", "AIFF", "-d", "BEI16@\(rate)", "-c", String(source.channels)]
        case "m4a": arguments = ["-f", "m4af", "-d", "aac", "-b", "64000"]
        default: arguments = ["-f", "caff", "-d", "LEI16@\(rate)", "-c", String(source.channels)]
        }
        arguments.append(contentsOf: [inputPath, outputPath])
        let result = try Proc.run(afconvert, arguments, timeout: 120)
        guard result.ok, FileManager.default.fileExists(atPath: outputPath) else {
            throw MacAIError("音频转换失败: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public static func json(_ result: Result) -> [String: Any] {
        [
            "path": result.path,
            "bytes": result.bytes,
            "ms": result.milliseconds,
            "engine": result.engine,
            "voice_id": result.voiceIdentifier,
            "voice_name": result.voiceName,
            "sample_rate": result.sampleRate,
            "duration_seconds": result.durationSeconds,
        ]
    }

    // MARK: - 试听样本（选音色用：光看名字选不出来，必须听）

    public struct Sample {
        public let voice: Voice
        public let path: String?
        public let bytes: Int64
        public let milliseconds: Double
        public let error: String?
    }

    /// 给每个音色合成一句样音，写到 `outputDir`。**单个音色失败不影响整批**（返回时带 error）。
    /// 文本里可用 `{name}`（音色名）与 `{lang}`（语言）占位。
    public static func samples(voices list: [Voice], textTemplate: String, outputDir: String,
                               format: String = "wav", rate: Double? = nil, pitch: Double? = nil) -> [Sample] {
        let directory = URL(fileURLWithPath: Support.expand(outputDir))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var results: [Sample] = []
        for (index, voice) in list.enumerated() {
            var options = Options()
            options.text = textTemplate
                .replacingOccurrences(of: "{name}", with: voice.name)
                .replacingOccurrences(of: "{lang}", with: voice.language)
            options.voice = voice.identifier
            options.rate = rate
            options.pitch = pitch
            options.format = format
            let safeName = voice.name.replacingOccurrences(of: " ", with: "_")
            options.outputPath = directory
                .appendingPathComponent(String(format: "%02d-%@-%@.%@", index + 1, safeName, voice.language, format)).path
            do {
                let result = try synthesize(options)
                results.append(Sample(voice: voice, path: result.path, bytes: result.bytes,
                                      milliseconds: result.milliseconds, error: nil))
            } catch {
                results.append(Sample(voice: voice, path: nil, bytes: 0, milliseconds: 0, error: "\(error)"))
            }
        }
        return results
    }

    public static func json(_ sample: Sample) -> [String: Any] {
        var payload: [String: Any] = [
            "voice_id": sample.voice.identifier,
            "name": sample.voice.name,
            "language": sample.voice.language,
            "gender": sample.voice.gender,
            "quality": sample.voice.quality,
            "novelty": sample.voice.novelty,
            "bytes": sample.bytes,
            "ms": sample.milliseconds,
        ]
        if let path = sample.path { payload["path"] = path }
        if let error = sample.error { payload["error"] = error }
        return payload
    }
}

/// 只用来知道"合成结束" —— 回调触发顺序在长文本下不可靠，必须有个终态信号。
final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var finished = false
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished = true
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished = true
    }
}
