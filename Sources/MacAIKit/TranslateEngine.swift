import Foundation
import Translation

/// 系统翻译（Translation.framework）—— 完全离线、不外发数据。
///
/// ⚠️ 现实约束：语言包**没有** API 可下载（`LanguageAvailability` 只有状态查询）。
/// 未安装时系统抛 `notInstalled`，本引擎把它翻译成**可执行的指引**而不是一句 "failed"。
public enum TranslateEngine {
    public struct PairStatus {
        public let source: String
        public let target: String
        public let state: String
        public var installed: Bool { state == "installed" }
        public var supported: Bool { state != "unsupported" }
    }

    public struct Result {
        public let sourceText: String
        public let targetText: String
        public let sourceLanguage: String
        public let targetLanguage: String
        public let milliseconds: Double
    }

    public static let commonLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "ru", "pt", "it", "ar"]

    static func language(_ tag: String) -> Locale.Language {
        Locale.Language(identifier: Support.normalizeLanguageTag(tag) ?? tag)
    }

    static func stateName(_ status: LanguageAvailability.Status) -> String {
        if status == .installed { return "installed" }
        if status == .supported { return "supported" }
        return "unsupported"
    }

    public static func status(source: String, target: String) throws -> PairStatus {
        try STTEngine.blocking {
            let availability = LanguageAvailability()
            let state = await availability.status(from: language(source), to: language(target))
            return PairStatus(source: source, target: target, state: stateName(state))
        }
    }

    /// 未给源语言时用 NaturalLanguage 自己判（系统只提供 `status(for text:)` 的自动判定，
    /// 但那条路径**不返回**它认定了哪种语言，而我们后面建会话必须显式给出源语言）。
    public static func detectSource(_ text: String) -> String? {
        NLPEngine.detectLanguage(text).0
    }

    public static func statusMatrix(source: String? = nil, target: String? = nil) throws -> [PairStatus] {
        var pairs: [(String, String)] = []
        if let source, let target {
            pairs = [(source, target)]
        } else if let target {
            pairs = commonLanguages.filter { $0 != target }.map { ($0, target) }
        } else {
            for source in commonLanguages where source != "en" {
                pairs.append(("en", source))
                pairs.append((source, "en"))
            }
        }
        return try STTEngine.blocking {
            let availability = LanguageAvailability()
            var results: [PairStatus] = []
            for (from, to) in pairs {
                let state = await availability.status(from: language(from), to: language(to))
                results.append(PairStatus(source: from, target: to, state: stateName(state)))
            }
            return results
        }
    }

    public static func installedHints(_ statuses: [PairStatus]) -> [String] {
        statuses.filter(\.installed).map { "\($0.source) → \($0.target)" }
    }

    public static func translate(text: String, source: String?, target: String, timeout: Double = 180) throws -> Result {
        let targetLanguage = language(target)
        let sourceTag: String
        if let source {
            sourceTag = source
        } else if let detected = detectSource(text) {
            sourceTag = detected
        } else {
            throw MacAIError("判断不出源语言", hint: "显式传 --from <语言>（如 en / zh-Hans）")
        }
        let sourceLanguage = language(sourceTag)

        return try STTEngine.blocking {
            let availability = LanguageAvailability()
            let state = await availability.status(from: sourceLanguage, to: targetLanguage)
            if state == .unsupported {
                throw MacAIError("系统不支持 \(sourceTag) → \(target) 的翻译",
                                 hint: "用 `macai translate --status` 看系统支持的语言对",
                                 code: ExitCode.unavailable)
            }
            if state != .installed {
                throw MacAIError("\(sourceTag) → \(target) 的语言包还没下载（状态: \(stateName(state))）",
                                 hint: installHint(sourceTag, target),
                                 code: ExitCode.unavailable)
            }
            // 看门狗：语言包虽然在，但系统仍可能在首次翻译时联网补齐资产 —— 不能让调用方无限等。
            return try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask { try await perform(text: text, source: sourceLanguage, target: targetLanguage, sourceTag: sourceTag, targetTag: target, state: state) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                    throw MacAIError("翻译超时（\(Int(timeout))s）",
                                     hint: "系统可能在为这个语言对补资产；先跑 `macai translate --status` 确认状态，或调大 --timeout",
                                     code: ExitCode.unavailable)
                }
                guard let first = try await group.next() else {
                    throw MacAIError("翻译没有返回结果")
                }
                group.cancelAll()
                return first
            }
        }
    }

    static func perform(text: String, source: Locale.Language, target: Locale.Language,
                        sourceTag: String, targetTag: String, state: LanguageAvailability.Status) async throws -> Result {
        let session = TranslationSession(installedSource: source, target: target)
        guard await session.isReady else {
            throw MacAIError("翻译会话未就绪（语言包可能只装了一半）", hint: installHint(sourceTag, targetTag),
                             code: ExitCode.unavailable)
        }
        let start = DispatchTime.now()
        do {
            let response = try await session.translate(text)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            return Result(sourceText: text, targetText: response.targetText,
                          sourceLanguage: response.sourceLanguage.maximalIdentifier,
                          targetLanguage: response.targetLanguage.maximalIdentifier,
                          milliseconds: ms)
        } catch {
            throw MacAIError("翻译失败: \(error)",
                             hint: "语言包状态 \(stateName(state))；\(installHint(sourceTag, targetTag))")
        }
    }

    static func installHint(_ source: String, _ target: String) -> String {
        "语言包只能手工下载一次：打开「翻译」App 选择该语言对触发下载，"
            + "或 系统设置 → 通用 → 语言与地区 →「翻译语言…」里添加 \(source) 与 \(target)；之后完全离线。"
    }

    public static func json(_ result: Result) -> [String: Any] {
        [
            "source_text": result.sourceText,
            "target_text": result.targetText,
            "source_language": result.sourceLanguage,
            "target_language": result.targetLanguage,
            "ms": result.milliseconds,
        ]
    }
}
