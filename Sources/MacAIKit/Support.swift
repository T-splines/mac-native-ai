import Foundation

// MARK: - 退出码约定（脚本/agent 依赖这些数字，改动即破坏契约）

public enum ExitCode {
    /// 成功
    public static let ok: Int32 = 0
    /// 参数或用法错误
    public static let usage: Int32 = 1
    /// 运行期失败：文件不可读、引擎报错
    public static let runtime: Int32 = 2
    /// 能力当前不可用：语音资产 / 翻译语言包未安装、系统版本不支持
    public static let unavailable: Int32 = 3
}

/// 统一的失败载体：`message` 给人看，`hint` 给出可执行的下一步。
public struct MacAIError: Error, CustomStringConvertible {
    public let message: String
    public let hint: String?
    public let code: Int32

    public init(_ message: String, hint: String? = nil, code: Int32 = ExitCode.runtime) {
        self.message = message
        self.hint = hint
        self.code = code
    }

    public var description: String {
        guard let hint, !hint.isEmpty else { return message }
        return "\(message)\n提示: \(hint)"
    }
}

// MARK: - 参数解析

/// 极简参数解析：`--key value` / `--key=value` / 已知布尔开关 / 其余按位置参数。
public struct Args {
    public private(set) var positional: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    /// 不接值的开关。**必须显式登记**，否则 `--json a.png` 会被吃成 `json=a.png`。
    private static let booleanNames: Set<String> = [
        "json", "fast", "barcode", "install-assets", "status", "all", "help", "version",
        "quiet", "verbose", "prefer-background", "no-correction", "force", "stdin",
        "caps", "list", "sample", "frames",
    ]

    public init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let token = raw[i]
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    values[String(body[body.startIndex..<eq])] = String(body[body.index(after: eq)...])
                } else if Self.booleanNames.contains(body) {
                    flags.insert(body)
                } else if i + 1 < raw.count && !raw[i + 1].hasPrefix("--") {
                    values[body] = raw[i + 1]
                    i += 1
                } else {
                    flags.insert(body)
                }
            } else if token == "-h" {
                flags.insert("help")
            } else {
                positional.append(token)
            }
            i += 1
        }
    }

    public func string(_ name: String) -> String? {
        guard let v = values[name], !v.isEmpty else { return nil }
        return v
    }

    public func string(_ name: String, default fallback: String) -> String {
        string(name) ?? fallback
    }

    public func bool(_ name: String) -> Bool { flags.contains(name) || values[name] == "true" }

    public func int(_ name: String, default fallback: Int) -> Int {
        guard let v = string(name) else { return fallback }
        return Int(v.trimmingCharacters(in: .whitespaces)) ?? fallback
    }

    public func double(_ name: String, default fallback: Double) -> Double {
        guard let v = string(name) else { return fallback }
        return Double(v.trimmingCharacters(in: .whitespaces)) ?? fallback
    }

    public func list(_ name: String) -> [String] {
        guard let v = string(name) else { return [] }
        return v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func has(_ name: String) -> Bool { values[name] != nil || flags.contains(name) }
}

// MARK: - 统一输出

public enum Out {
    /// 成功：`--json` 输出 `{"ok":true,"data":…}`，否则输出人读文本（无 human 时回落到 JSON）。
    public static func ok(_ data: Any, json: Bool, human: String? = nil) {
        if json || human == nil {
            print(JSONOut.render(["ok": true, "data": data]))
        } else {
            print(human!)
        }
    }

    /// 失败：`--json` 输出错误信封（形状见 `JSONOut.errorPayload`），否则输出 `错误: …` + `提示: …`。
    public static func fail(_ error: MacAIError, json: Bool) {
        if json {
            print(JSONOut.render(JSONOut.errorPayload(error)))
        } else {
            FileHandle.standardError.write(Data("错误: \(error.message)\n".utf8))
            if let hint = error.hint, !hint.isEmpty {
                FileHandle.standardError.write(Data("提示: \(hint)\n".utf8))
            }
        }
    }

    public static func warn(_ text: String) {
        FileHandle.standardError.write(Data("\(text)\n".utf8))
    }
}

// MARK: - JSON

public enum JSONOut {
    /// JSONSerialization 拒绝 NaN/Inf；统一在出口处净化，绝不静默产出非法 JSON。
    public static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as Double:
            return d.isFinite ? d : NSNull()
        case let f as Float:
            return f.isFinite ? Double(f) : NSNull()
        case let dict as [String: Any]:
            return dict.mapValues(sanitize)
        case let arr as [Any]:
            return arr.map(sanitize)
        default:
            return value
        }
    }

    public static func render(_ value: Any, pretty: Bool = true) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(sanitize(value)),
              let data = try? JSONSerialization.data(withJSONObject: sanitize(value), options: options),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{\"ok\":false,\"error\":\"internal: 结果无法序列化为 JSON\"}"
        }
        return text
    }

    /// 失败信封（CLI 与 MCP 共用）：
    /// `{"ok": false, "code": 2, "message": "…", "retryable": true, "remediation": "…"}`。
    ///
    /// 兼容别名：`error`（CLI 自 0.1.0 起的字段，脚本与 e2e 在断言它）与 `hint`（旧字段）。
    /// 两个别名都只是 `message` / `remediation` 的拷贝，**真源各一份**，不给调用方第二种解读。
    ///
    /// `retryable` 是这次新增的决策字段：调用方不必背退出码表就能决定要不要重试。
    public static func errorPayload(_ error: MacAIError) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": false,
            "code": Int(error.code),
            "message": error.message,
            "error": error.message,   // 兼容别名
            "retryable": isRetryable(error.code),
        ]
        if let hint = error.hint, !hint.isEmpty {
            payload["remediation"] = hint
            payload["hint"] = hint    // 兼容别名
        }
        return payload
    }

    /// 哪些失败值得重试：
    /// - 参数错（1）、能力不可用（3）→ false，改了也还是同一个结果；
    /// - 运行失败（2，文件读不到 / 引擎报错 / 超时）→ true，可能只是瞬时状态；
    /// - 未知码 → false。**宁可少让调用方重试**，也不要把硬错误说成可重试。
    public static func isRetryable(_ code: Int32) -> Bool {
        code == ExitCode.runtime
    }

    /// 把一段原始 JSON 文本解析成对象（MCP 入参用）。
    public static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

// MARK: - stdin 长度前缀帧流（一次进程识别多张图）

/// `macai ocr - --frames` 的帧流：`{ [u32 大端 长度][该长度的图片字节] } … [u32 大端 0]`。
///
/// 设计要点（都是验收项，改动即破坏契约）：
/// - 每帧长度必须 > 0；`0` 是终止符；**EOF 也可正常结束**（管道天然如此）；
///   终止符之后不得再有字节（有则报错，**不允许静默忽略**）。
/// - **先校验再分配**：读长度 → 校验上限 → 才去读该帧的字节；绝不按来路不明的长度预分配内存。
/// - 上限：单帧 ≤ 64 MiB、帧数 ≤ 64、总量 ≤ 256 MiB（`Limits` 可调，默认值即文档值）。
/// - 退出码语义：**流的字节内容**有问题（截断 / 超限 / 终止符后有字节 / 不是图片）→ 2（运行失败）；
///   **命令行用法**有问题（`--frames` 没配 `-`、空流）→ 1（参数错）。
public enum FrameStream {
    public struct Limits: Equatable {
        public var maxFrameBytes: Int
        public var maxFrames: Int
        public var maxTotalBytes: Int

        public init(maxFrameBytes: Int = 64 * 1024 * 1024,
                    maxFrames: Int = 64,
                    maxTotalBytes: Int = 256 * 1024 * 1024) {
            self.maxFrameBytes = maxFrameBytes
            self.maxFrames = maxFrames
            self.maxTotalBytes = maxTotalBytes
        }
    }

    /// 默认上限（文档里写的就是这三个数）。
    public static let limits = Limits()

    /// 出错时统一挂这条格式说明，用户不必去翻文档。
    public static let formatHint = "帧流格式: { [u32 大端长度][该长度的图片字节] } … [u32 大端 0]（0 是终止符，EOF 也可结束）；见 macai help 的 ocr 一节"

    /// 解析内存里的完整帧流（spec 用；CLI 走 `readFromStdin`，两者共用同一份校验逻辑）。
    public static func parse(_ data: Data, limits: Limits = FrameStream.limits) throws -> [Data] {
        var cursor = data.startIndex
        return try read(limits: limits) { count in
            guard cursor < data.endIndex else { return Data() }
            let end = data.index(cursor, offsetBy: count, limitedBy: data.endIndex) ?? data.endIndex
            defer { cursor = end }
            return data[cursor..<end]
        }
    }

    /// 从 stdin 读帧流。**边读边校验**：声明超限的帧在读到它的字节之前就被拒。
    public static func readFromStdin(limits: Limits = FrameStream.limits) throws -> [Data] {
        guard isatty(STDIN_FILENO) == 0 else {
            throw MacAIError("stdin 没有数据（当前是终端，不是管道）",
                             hint: "把帧流管道进来，例如: cat frames.bin | macai ocr - --frames",
                             code: ExitCode.usage)
        }
        let handle = FileHandle.standardInput
        return try read(limits: limits) { count in
            do {
                return try handle.read(upToCount: count) ?? Data()
            } catch {
                throw MacAIError("读 stdin 失败: \(error.localizedDescription)")
            }
        }
    }

    /// 通用拉取式解析：`reader(n)` 返回**最多** n 字节（管道短读是正常的），返回空表示 EOF。
    public static func read(limits: Limits = FrameStream.limits, _ reader: (Int) throws -> Data) throws -> [Data] {
        var frames: [Data] = []
        var total = 0
        while true {
            let header = try readUpTo(4, reader)
            if header.isEmpty { break }   // EOF：正常结束（管道不给终止符也能用）
            guard header.count == 4 else {
                throw MacAIError("帧流被截断：尾部只剩 \(header.count) 字节，读不出 4 字节长度前缀",
                                 hint: formatHint, code: ExitCode.runtime)
            }
            let bytes = [UInt8](header)
            let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            if length == 0 {
                let trailing = try readUpTo(1, reader)
                guard trailing.isEmpty else {
                    throw MacAIError("终止符（u32 大端 0）之后还有字节",
                                     hint: "一个流只描述一个帧流；\(formatHint)", code: ExitCode.runtime)
                }
                return frames
            }
            let index = frames.count + 1
            guard frames.count < limits.maxFrames else {
                throw MacAIError("帧数超过上限（最多 \(limits.maxFrames) 帧，第 \(index) 帧被拒）",
                                 hint: formatHint, code: ExitCode.runtime)
            }
            guard length <= limits.maxFrameBytes else {
                throw MacAIError("第 \(index) 帧声明 \(length) 字节，超过单帧上限 \(limits.maxFrameBytes) 字节（\(limits.maxFrameBytes / 1024 / 1024) MiB）",
                                 hint: "在读到它的字节之前就拒绝，避免按来路不明的长度分配内存；\(formatHint)",
                                 code: ExitCode.runtime)
            }
            guard total + length <= limits.maxTotalBytes else {
                throw MacAIError("帧流总量超过上限（已读 \(total) 字节 + 本帧 \(length) 字节 > \(limits.maxTotalBytes) 字节）",
                                 hint: formatHint, code: ExitCode.runtime)
            }
            let body = try readUpTo(length, reader)
            guard body.count == length else {
                throw MacAIError("第 \(index) 帧被截断：声明 \(length) 字节，实际只有 \(body.count) 字节",
                                 hint: formatHint, code: ExitCode.runtime)
            }
            frames.append(body)
            total += length
        }
        return frames
    }

    /// 读满 `count` 字节或到 EOF（短读继续要，直到 EOF）。
    private static func readUpTo(_ count: Int, _ reader: (Int) throws -> Data) throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try reader(count - buffer.count)
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        return buffer
    }
}

// MARK: - 外部进程

public struct Proc {
    public struct Result {
        public let status: Int32
        public let out: String
        public let err: String
        public var ok: Bool { status == 0 }
    }

    public static func which(_ name: String, extraDirs: [String] = []) -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        dirs.append(contentsOf: extraDirs)
        for dir in dirs where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// 找 ffmpeg：PATH → Homebrew → `~/.local/bin`。
    public static func findFFmpeg() -> String? {
        if let p = which("ffmpeg") { return p }
        var candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append((home as NSString).appendingPathComponent(".local/bin/ffmpeg"))
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    @discardableResult
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 300) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw MacAIError("无法启动 \(path): \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var outData = Data()
        var errData = Data()
        // 先读完管道再 waitUntilExit，避免子进程写满管道缓冲后死锁。
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let group = DispatchGroup()
        var collected: [Int: Data] = [:]
        let lock = NSLock()
        group.enter()
        DispatchQueue.global().async {
            let d = outHandle.readDataToEndOfFile()
            lock.lock(); collected[0] = d; lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let d = errHandle.readDataToEndOfFile()
            lock.lock(); collected[1] = d; lock.unlock()
            group.leave()
        }
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw MacAIError("\(URL(fileURLWithPath: path).lastPathComponent) 超时（\(Int(timeout))s）")
        }
        group.wait()
        lock.lock()
        outData = collected[0] ?? Data()
        errData = collected[1] ?? Data()
        lock.unlock()
        return Result(status: process.terminationStatus,
                      out: String(data: outData, encoding: .utf8) ?? "",
                      err: String(data: errData, encoding: .utf8) ?? "")
    }
}

// MARK: - 杂项

public enum Support {
    public static func tempDir(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 计时：（结果, 毫秒）
    public static func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
        let start = DispatchTime.now()
        let value = try body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        return (value, ms)
    }

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public static func fileSize(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: expand(path))
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public static func readText(_ path: String) throws -> String {
        let expanded = expand(path)
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw MacAIError("读不到文本文件: \(path)")
        }
        return text
    }

    /// 读 stdin 全部字节。TTY（没管道）直接报错，**绝不阻塞等输入**；空输入同样报错。
    public static func readStdinData() throws -> Data {
        guard isatty(STDIN_FILENO) == 0 else {
            throw MacAIError("stdin 没有数据（当前是终端，不是管道）",
                             hint: "把图片字节管道进来，例如: cat img.png | macai ocr -",
                             code: ExitCode.usage)
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            throw MacAIError("stdin 是空的",
                             hint: "管道没有送来任何字节，例如: cat img.png | macai ocr -",
                             code: ExitCode.usage)
        }
        return data
    }

    public static func writeText(_ text: String, to path: String) throws {
        let expanded = expand(path)
        try FileManager.default.createDirectory(atPath: (expanded as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { throw MacAIError("文本无法编码为 UTF-8") }
        try data.write(to: URL(fileURLWithPath: expanded))
    }

    /// `zh` / `zh-CN` / `Chinese` → BCP-47；无法识别时原样返回由系统自行协商。
    public static func normalizeLanguageTag(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        switch lowered {
        case "zh", "zh-cn", "zh-hans", "chinese", "mandarin", "中文", "简体", "chinese (simplified)": return "zh-Hans"
        case "zh-tw", "zh-hant", "zh-hk", "traditional": return "zh-Hant"
        case "en", "english": return "en-US"
        case "ja", "japanese": return "ja-JP"
        case "ko", "korean": return "ko-KR"
        case "auto", "detect": return nil
        default: return raw
        }
    }

    /// 秒 → `HH:MM:SS,mmm`（SRT 时间戳）
    public static func srtTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMs = Int((clamped * 1000).rounded())
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let s = totalSec % 60
        let m = (totalSec / 60) % 60
        let h = totalSec / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    public static func version() -> String { "0.1.0" }
}
