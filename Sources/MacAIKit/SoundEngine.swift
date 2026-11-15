import Foundation
import SoundAnalysis
import AVFoundation

/// SoundAnalysis 内置声音分类器（约 300 类，无需自定义模型）。
public enum SoundEngine {
    public struct Window {
        public let label: String
        public let confidence: Double
        public let start: Double
        public let end: Double
    }

    public struct Result {
        public let file: String
        public let duration: Double
        public let milliseconds: Double
        public let windows: [Window]
        public var labels: [(String, Double)] {
            var best: [String: Double] = [:]
            for window in windows {
                best[window.label] = max(best[window.label] ?? 0, window.confidence)
            }
            return best.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        }
    }

    public static func classify(path: String, top: Int = 3, overlap: Double = 0.5) throws -> Result {
        // `prefix(top)` traps on a negative count, so reject it here instead of letting
        // a bad CLI/MCP argument end the process without an error envelope.
        guard top >= 1 else {
            throw MacAIError("top 必须是 ≥ 1 的整数", hint: "例如 --top 3", code: ExitCode.usage)
        }
        let url = URL(fileURLWithPath: Support.expand(path))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MacAIError("音频文件不存在: \(path)")
        }
        let request: SNClassifySoundRequest
        do {
            request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        } catch {
            throw MacAIError("内置声音分类器不可用: \(error.localizedDescription)")
        }
        request.overlapFactor = min(max(overlap, 0), 1)

        let duration = (try? AVAudioFile(forReading: url)).map { file -> Double in
            file.fileFormat.sampleRate > 0 ? Double(file.length) / file.fileFormat.sampleRate : 0
        } ?? 0

        let observer = Observer(top: top)
        do {
            let analyzer = try SNAudioFileAnalyzer(url: url)
            try analyzer.add(request, withObserver: observer)
            let (_, milliseconds) = try Support.timed { try analyzer.analyze() }
            return Result(file: url.path, duration: duration, milliseconds: milliseconds, windows: observer.windows)
        } catch let error as MacAIError {
            throw error
        } catch {
            throw MacAIError("声音分析失败: \(error.localizedDescription)")
        }
    }

    public static func json(_ result: Result, top: Int) -> [String: Any] {
        [
            "file": result.file,
            "duration_seconds": result.duration,
            "ms": result.milliseconds,
            "window_count": result.windows.count,
            "top_labels": result.labels.prefix(top).map { ["label": $0.0, "confidence": $0.1] },
            "timeline": result.windows.map { ["label": $0.label, "confidence": $0.confidence, "start": $0.start, "end": $0.end] },
        ]
    }

    final class Observer: NSObject, SNResultsObserving {
        private(set) var windows: [Window] = []
        private let top: Int
        init(top: Int) { self.top = top }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            let start = classification.timeRange.start.seconds
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(classification.timeRange))
            for item in classification.classifications.prefix(max(1, top)) {
                windows.append(Window(label: item.identifier, confidence: Double(item.confidence), start: start, end: end))
            }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            Out.warn("⚠️ 声音分析中断: \(error.localizedDescription)")
        }
    }
}
