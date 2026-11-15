import Foundation
import NaturalLanguage

/// NaturalLanguage 框架：语种识别 / 分词 / 词性 / 命名实体 / 句子切分。
///
/// ⚠️ 坑：`enumerateTags` 只会回调**当前 scheme 能打上标签**的片段 —— 若把
/// `.nameType` 直接当遍历 scheme，未命中实体的词会被**整段跳过**（表现为"分词结果为空"）。
/// 所以遍历一律走 `.lexicalClass`（每个词都有），其余标签用 `tag(at:)` 单独查。
public enum NLPEngine {
    public struct Token {
        public let text: String
        public let pos: String?
        public let entity: String?
        public let lemma: String?
    }

    public struct Analysis {
        public let text: String
        public let language: String?
        public let languageHypotheses: [(String, Double)]
        public let tokens: [Token]
        public let sentences: [String]
        public let entities: [String]
    }

    public static func detectLanguage(_ text: String) -> (String?, [(String, Double)]) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
            .map { ($0.key.rawValue, Double($0.value)) }
            .sorted { $0.1 > $1.1 }
        return (recognizer.dominantLanguage?.rawValue, hypotheses)
    }

    public static func analyze(_ text: String) -> Analysis {
        let (language, hypotheses) = detectLanguage(text)
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .lemma, .tokenType])
        tagger.string = text
        if let language {
            tagger.setLanguage(NLLanguage(rawValue: language), range: text.startIndex..<text.endIndex)
        }

        var tokens: [Token] = []
        var entities: [String] = []
        // nameType 的标签里 "OtherWord" 表示"不是实体"，白名单比黑名单可靠。
        let entityTags: Set<String> = ["PersonalName", "PlaceName", "OrganizationName"]
        let full = text.startIndex..<text.endIndex
        tagger.enumerateTags(in: full, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let token = String(text[range])
            let (entityTag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType)
            let (lemmaTag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma)
            if let entityTag, entityTags.contains(entityTag.rawValue) {
                entities.append("\(token)=\(entityTag.rawValue)")
            }
            tokens.append(Token(text: token,
                                pos: tag?.rawValue,
                                entity: entityTag?.rawValue,
                                lemma: lemmaTag?.rawValue))
            return true
        }

        var sentences: [String] = []
        tagger.enumerateTags(in: full, unit: .sentence, scheme: .tokenType, options: []) { _, range in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }

        return Analysis(text: text, language: language, languageHypotheses: hypotheses,
                        tokens: tokens, sentences: sentences, entities: entities)
    }

    public static func json(_ analysis: Analysis) -> [String: Any] {
        [
            "text": analysis.text,
            "language": analysis.language ?? "",
            "language_hypotheses": analysis.languageHypotheses.map { ["language": $0.0, "confidence": $0.1] },
            "token_count": analysis.tokens.count,
            "tokens": analysis.tokens.map { token -> [String: Any] in
                var item: [String: Any] = ["text": token.text]
                if let pos = token.pos { item["pos"] = pos }
                if let entity = token.entity, entity != "Other" { item["entity"] = entity }
                if let lemma = token.lemma { item["lemma"] = lemma }
                return item
            },
            "entities": analysis.entities,
            "sentences": analysis.sentences,
        ]
    }
}
