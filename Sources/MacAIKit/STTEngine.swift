import Foundation
import Speech
import AVFoundation
import CoreMedia

/// 系统语音识别（macOS 26 的 SpeechAnalyzer / SpeechTranscriber）。
///
/// ⚠️ 为什么不用 SFSpeechRecognizer：它在 CLI 形态下拿不到 TCC 授权 ——
/// 实测 `requestAuthorization` 恒回 `notDetermined`（嵌 `__info_plist` 也一样），
/// 语音识别服务对「非 App Bundle 的 CLI」不会弹窗。`SpeechTranscriber` 走的是
/// 系统语音模型资产（AssetInventory），**不需要 TCC 授权**，且完全离线。
public enum STTEngine {
    public struct Options {
        public var audioPath: String = ""
        public var locale: String = "zh-CN"
        public var timeout: Double = 300
        public var installAssets = false
        public var rawSpacing = false
        public init() {}
    }

    public struct Segment {
        public let text: String
        public let start: Double
        public let end: Double
    }

    public struct Result {
        public let text: String
        public let rawText: String
        public let segments: [Segment]
        public let locale: String
        public let milliseconds: Double
        public let audioSeconds: Double
    }

    public enum AssetState: String {
        case unsupported, supported, downloading, installed, unknown
    }

    // MARK: - async → sync 桥

    /// 把 async 引擎包成同步调用（CLI 与 MCP 都是同步入口）。
    public static func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            do { box.value = .success(try await body()) }
            catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.value {
        case .success(let value): return value
        case .failure(let error): throw error
        case .none: throw MacAIError("内部错误：异步任务没有返回结果")
        }
    }

    final class ResultBox<T>: @unchecked Sendable {
        var value: Swift.Result<T, Error>?
    }

    // MARK: - 查询

    public static func supportedLocales() -> [String] {
        (try? blocking { await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) } }) ?? []
    }

    public static func jsonAssetState(_ locale: String) throws -> [String: Any] {
        try blocking {
            let (transcriber, resolved) = try await makeTranscriber(locale)
            let state = await assetState(transcriber)
            return ["locale": resolved.identifier(.bcp47),
                    "requested_locale": locale,
                    "asset_state": state.rawValue,
                    "installed": state == .installed,
                    "supported_locales": await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }]
        }
    }

    public static func installAssets(locale: String) throws -> [String: Any] {
        try blocking {
            let (transcriber, resolved) = try await makeTranscriber(locale)
            let before = await assetState(transcriber)
            if before != .installed {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                    throw MacAIError("系统没有为该语言提供可下载的语音资产",
                                     hint: "用 `macai stt --status --locale <语言>` 查看支持的语言",
                                     code: ExitCode.unavailable)
                }
                try await request.downloadAndInstall()
            }
            let after = await assetState(transcriber)
            return ["locale": resolved.identifier(.bcp47), "asset_state_before": before.rawValue,
                    "asset_state_after": after.rawValue, "installed": after == .installed]
        }
    }

    // MARK: - 转写

    public static func transcribe(_ options: Options) throws -> Result {
        try blocking { try await transcribeAsync(options) }
    }

    static func makeTranscriber(_ localeIdentifier: String) async throws -> (SpeechTranscriber, Locale) {
        let requested = Locale(identifier: localeIdentifier)
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
            throw MacAIError("系统语音识别不支持语言 '\(localeIdentifier)'",
                             hint: "支持的语言：\(supported.joined(separator: ", "))",
                             code: ExitCode.unavailable)
        }
        // attributeOptions 里必须带 audioTimeRange —— 否则拿不到每段的时间轴，SRT 就只能是空的。
        let transcriber = SpeechTranscriber(locale: resolved, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        return (transcriber, resolved)
    }

    static func assetState(_ transcriber: SpeechTranscriber) async -> AssetState {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed { return .installed }
        if status == .supported { return .supported }
        if status == .downloading { return .downloading }
        if status == .unsupported { return .unsupported }
        return .unknown
    }

    static func transcribeAsync(_ options: Options) async throws -> Result {
        let (transcriber, resolved) = try await makeTranscriber(options.locale)
        let state = await assetState(transcriber)
        switch state {
        case .installed:
            break
        case .supported, .downloading:
            if options.installAssets {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } else {
                throw MacAIError("\(resolved.identifier(.bcp47)) 的语音资产还没安装（首次需要联网下载一次）",
                                 hint: "先跑 `macai stt --install-assets --locale \(resolved.identifier(.bcp47))`",
                                 code: ExitCode.unavailable)
            }
        case .unsupported:
            throw MacAIError("系统不支持 \(resolved.identifier(.bcp47)) 的语音识别", code: ExitCode.unavailable)
        case .unknown:
            throw MacAIError("语音资产状态未知，无法转写", code: ExitCode.unavailable)
        }

        let prepared = try prepareAudio(options.audioPath)
        defer { if let dir = prepared.cleanupDir { try? FileManager.default.removeItem(at: dir) } }

        guard let audioFile = try? AVAudioFile(forReading: prepared.url) else {
            throw MacAIError("系统解码不了这个音频: \(options.audioPath)",
                             hint: "转成 wav/m4a/aiff 再试，或安装 ffmpeg 让 macai 自动转码")
        }
        let audioSeconds = audioFile.fileFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.fileFormat.sampleRate : 0

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Segment] in
            var segments: [Segment] = []
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let start = result.range.start.seconds
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                    segments.append(Segment(text: text, start: start, end: end))
                }
            } catch {
                Out.warn("⚠️ 转写结果流中断: \(error.localizedDescription)")
            }
            return segments
        }

        let start = DispatchTime.now()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await analyzer.analyzeSequence(from: audioFile)
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(1, options.timeout) * 1_000_000_000))
                    throw MacAIError("转写超时（\(Int(options.timeout))s）")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let segments = await collector.value

        let rawText = segments.map(\.text).joined()
        let text = options.rawSpacing ? rawText : normalizeTranscript(rawText)
        return Result(text: text, rawText: rawText, segments: segments,
                      locale: resolved.identifier(.bcp47), milliseconds: milliseconds,
                      audioSeconds: audioSeconds)
    }

    /// 音频预处理：系统解码不了（ogg / opus / silk 等）时用 ffmpeg 转成 16 kHz 单声道 wav。
    static func prepareAudio(_ path: String) throws -> (url: URL, cleanupDir: URL?) {
        let expanded = Support.expand(path)
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw MacAIError("音频文件不存在: \(path)")
        }
        let url = URL(fileURLWithPath: expanded)
        if (try? AVAudioFile(forReading: url)) != nil { return (url, nil) }
        guard let ffmpeg = Proc.findFFmpeg() else {
            throw MacAIError("系统解不开 \(url.pathExtension.isEmpty ? "该格式" : url.pathExtension) 音频，且没找到 ffmpeg",
                             hint: "安装 ffmpeg（brew install ffmpeg）即可自动转码；或先手工转成 wav/m4a")
        }
        let dir = try Support.tempDir("macai-stt-src")
        let wav = dir.appendingPathComponent("audio.wav")
        let result = try Proc.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", expanded,
                                           "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path], timeout: 600)
        guard result.ok, FileManager.default.fileExists(atPath: wav.path) else {
            try? FileManager.default.removeItem(at: dir)
            throw MacAIError("ffmpeg 转码失败: \(result.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return (wav, dir)
    }

    /// 系统的中文结果会在中文/标点/数字两侧插空格（`你好 ，这是 10 月 7 号`）。
    /// 规则（保守）：**只在中文一侧粘连**——中文↔中文、中文↔数字之间去掉空格；
    /// 拉丁字母与中文之间的空格**保留**（`hello world 你好` 不动），避免把英文单词粘到汉字上。
    public static func normalizeTranscript(_ input: String) -> String {
        // ⚠️ ICU 正则只认 \uHHHH，不认 Swift 的 \u{HHHH} —— 写错的表现是"一个都没匹配上"。
        let cjk = "\\u4E00-\\u9FFF\\u3400-\\u4DBF\\u3000-\\u303F\\uFF00-\\uFFEF"
        let patterns: [(pattern: String, template: String)] = [
            ("([\(cjk)])([ ]+)([\(cjk)])", "$1$3"),
            ("([\(cjk)])([ ]+)([0-9])", "$1$3"),
            ("([0-9])([ ]+)([\(cjk)])", "$1$3"),
        ]
        var output = input
        for item in patterns {
            guard let regex = try? NSRegularExpression(pattern: item.pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: item.template)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func json(_ result: Result) -> [String: Any] {
        [
            "text": result.text,
            "raw_text": result.rawText,
            "locale": result.locale,
            "ms": result.milliseconds,
            "audio_seconds": result.audioSeconds,
            "segment_count": result.segments.count,
            "segments": result.segments.map { ["text": $0.text, "start": $0.start, "end": $0.end] },
        ]
    }

    public static func srt(_ result: Result) -> String {
        guard !result.segments.isEmpty else { return "" }
        var lines: [String] = []
        for (index, segment) in result.segments.enumerated() {
            let text = normalizeTranscript(segment.text)
            guard !text.isEmpty else { continue }
            lines.append("\(lines.count / 3 + 1)")
            lines.append("\(Support.srtTimestamp(segment.start)) --> \(Support.srtTimestamp(max(segment.end, segment.start + 0.2)))")
            lines.append(text)
            lines.append("")
            _ = index
        }
        return lines.joined(separator: "\n")
    }
}
