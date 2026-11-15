import Foundation
import Vision
import ImageIO
import CoreGraphics

/// Vision 框架文字识别 + 条码识别。
public enum OCREngine {
    public struct Options {
        public var languages: [String] = []
        public var fast = false
        public var usesLanguageCorrection = true
        public var maxWidth = 2400
        public var preferBackground = false
        public var barcodes = false
        public init() {}
    }

    public struct Line: Equatable {
        public let text: String
        public let confidence: Double
        /// 像素坐标（左上原点），便于直接对着原图裁剪。
        public let box: [Int]
        public let candidates: [String]
    }

    public struct Barcode {
        public let payload: String?
        public let symbology: String
        public let box: [Int]
    }

    public struct Page {
        public let file: String
        public let width: Int
        public let height: Int
        public let scaled: Bool
        public let milliseconds: Double
        public let lines: [Line]
        public let barcodes: [Barcode]
        public var text: String { lines.map(\.text).joined(separator: "\n") }
    }

    /// 读图；宽度超过 `maxWidth` 时按 ImageIO 缩略图路径降采样（用户调研提示：大图直接喂 Vision 会顶内存）。
    public static func loadImage(path: String, maxWidth: Int) throws -> (image: CGImage, width: Int, height: Int, scaled: Bool) {
        let url = URL(fileURLWithPath: Support.expand(path))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MacAIError("图片不存在: \(path)")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MacAIError("无法解析图片（格式不支持或文件损坏）: \(path)")
        }
        return try imageFromSource(source, maxWidth: maxWidth, label: path)
    }

    /// 从 stdin 读来的图片字节建源（**不落盘**）；解析与降采样逻辑与文件路径完全一致。
    public static func loadImage(stdin data: Data, maxWidth: Int) throws -> (image: CGImage, width: Int, height: Int, scaled: Bool) {
        guard !data.isEmpty else {
            throw MacAIError("stdin 是空的", hint: "把图片字节管道进来，例如: cat img.png | macai ocr -", code: ExitCode.usage)
        }
        return try decode(data: data, maxWidth: maxWidth, label: "-",
                          parseMessage: "无法解析图片（stdin 内容不是受支持的图片格式）",
                          parseHint: "确认管道进来的是 PNG/JPEG 等图片字节，例如: cat img.png | macai ocr -")
    }

    /// 帧流（`--frames`）里的第 `index` 帧（从 1 起）：错误文案**必须点名第几帧**（验收要求）。
    public static func loadImage(frame data: Data, index: Int, maxWidth: Int) throws -> (image: CGImage, width: Int, height: Int, scaled: Bool) {
        guard !data.isEmpty else {
            throw MacAIError("第 \(index) 帧是空的（帧长度必须 > 0）",
                             hint: FrameStream.formatHint, code: ExitCode.runtime)
        }
        return try decode(data: data, maxWidth: maxWidth, label: "<stdin>#\(index)",
                          parseMessage: "第 \(index) 帧不是受支持的图片",
                          parseHint: "确认第 \(index) 帧里是 PNG/JPEG 等图片字节；\(FrameStream.formatHint)")
    }

    /// 数据源共用：建源 → 出图。ImageIO 的 data 源是惰性的（垃圾字节也能建源，取图才失败），
    /// 对调用方来说两者都是「无法解析图片」，统一映射成同一条错误。
    private static func decode(data: Data, maxWidth: Int, label: String,
                               parseMessage: String, parseHint: String) throws -> (image: CGImage, width: Int, height: Int, scaled: Bool) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw MacAIError(parseMessage, hint: parseHint, code: ExitCode.runtime)
        }
        do {
            return try imageFromSource(source, maxWidth: maxWidth, label: label)
        } catch {
            throw MacAIError(parseMessage, hint: parseHint, code: ExitCode.runtime)
        }
    }

    /// 文件源与数据源共用：取属性 → 按需降采样 → 出图。
    private static func imageFromSource(_ source: CGImageSource, maxWidth: Int, label: String) throws -> (image: CGImage, width: Int, height: Int, scaled: Bool) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let originalWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let originalHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0

        if maxWidth > 0, originalWidth > maxWidth {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxWidth,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw MacAIError("图片降采样失败: \(label)")
            }
            return (thumb, thumb.width, thumb.height, true)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MacAIError("图片解码失败: \(label)")
        }
        return (image, originalWidth > 0 ? originalWidth : image.width,
                originalHeight > 0 ? originalHeight : image.height, false)
    }

    public static func recognize(path: String, options: Options = Options()) throws -> Page {
        let (image, width, height, scaled) = try loadImage(path: path, maxWidth: options.maxWidth)
        return try performRecognition(image: image, width: width, height: height, scaled: scaled,
                                      options: options, file: Support.expand(path))
    }

    /// 识别从 stdin 读来的图片字节（CLI 路径写 `-` 时走这里）。
    public static func recognize(stdinData data: Data, options: Options = Options()) throws -> Page {
        let (image, width, height, scaled) = try loadImage(stdin: data, maxWidth: options.maxWidth)
        return try performRecognition(image: image, width: width, height: height, scaled: scaled,
                                      options: options, file: "<stdin>")
    }

    /// 识别帧流里的第 `index` 帧（`macai ocr - --frames`）；`file` 记 `<stdin>#index`（不落盘、不冒充路径）。
    public static func recognize(frame data: Data, index: Int, options: Options = Options()) throws -> Page {
        let (image, width, height, scaled) = try loadImage(frame: data, index: index, maxWidth: options.maxWidth)
        return try performRecognition(image: image, width: width, height: height, scaled: scaled,
                                      options: options, file: "<stdin>#\(index)")
    }

    private static func performRecognition(image: CGImage, width: Int, height: Int, scaled: Bool,
                                           options: Options, file: String) throws -> Page {

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = options.fast ? .fast : .accurate
        textRequest.usesLanguageCorrection = options.usesLanguageCorrection
        textRequest.preferBackgroundProcessing = options.preferBackground
        if !options.languages.isEmpty {
            textRequest.recognitionLanguages = options.languages
        }

        var requests: [VNRequest] = [textRequest]
        var barcodeRequest: VNDetectBarcodesRequest?
        if options.barcodes {
            let request = VNDetectBarcodesRequest()
            requests.append(request)
            barcodeRequest = request
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let (_, milliseconds) = try Support.timed {
            do {
                try handler.perform(requests)
            } catch {
                throw MacAIError("Vision 识别失败: \(error.localizedDescription)")
            }
        }

        let lines: [Line] = (textRequest.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return Line(text: candidate.string,
                        confidence: Double(candidate.confidence),
                        box: pixelBox(observation.boundingBox, width: width, height: height),
                        candidates: observation.topCandidates(3).map(\.string))
        }

        let barcodes: [Barcode] = (barcodeRequest?.results ?? []).map { observation in
            Barcode(payload: observation.payloadStringValue,
                    symbology: observation.symbology.rawValue,
                    box: pixelBox(observation.boundingBox, width: width, height: height))
        }

        return Page(file: file, width: width, height: height, scaled: scaled,
                    milliseconds: milliseconds, lines: lines, barcodes: barcodes)
    }

    /// Vision 的 boundingBox 是归一化 + 左下原点；这里换成像素 + 左上原点。
    private static func pixelBox(_ box: CGRect, width: Int, height: Int) -> [Int] {
        let w = Double(width), h = Double(height)
        let x = Int((box.minX * w).rounded())
        let y = Int(((1 - box.maxY) * h).rounded())
        return [x, y, Int((box.width * w).rounded()), Int((box.height * h).rounded())]
    }

    public static func supportedLanguages() -> [String] {
        (try? VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: VNRecognizeTextRequestRevision3)) ?? []
    }

    public static func json(_ page: Page, includeCandidates: Bool = false) -> [String: Any] {
        var payload: [String: Any] = [
            "file": page.file,
            "width": page.width,
            "height": page.height,
            "downscaled": page.scaled,
            "ms": page.milliseconds,
            "text": page.text,
            "line_count": page.lines.count,
            "lines": page.lines.map { line -> [String: Any] in
                var item: [String: Any] = ["text": line.text, "confidence": line.confidence, "box": line.box]
                if includeCandidates { item["candidates"] = line.candidates }
                return item
            },
        ]
        if !page.barcodes.isEmpty {
            payload["barcodes"] = page.barcodes.map { ["payload": $0.payload ?? "", "symbology": $0.symbology, "box": $0.box] }
        }
        return payload
    }
}
