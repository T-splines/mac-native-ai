// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "macai",
    // macOS 26 是硬底线：STT 走 Speech 框架的 SpeechTranscriber/SpeechAnalyzer（macOS 26 起可用），
    // 它能在不申请 TCC 授权的前提下离线转写；旧的 SFSpeechRecognizer 在 CLI 形态拿不到授权。
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MacAIKit", targets: ["MacAIKit"]),
        .executable(name: "macai", targets: ["macai"]),
    ],
    targets: [
        .target(
            name: "MacAIKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "macai",
            dependencies: ["MacAIKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 单测跑在自带的 spec 可执行文件里，而不用 XCTest / swift-testing：
        // 只装 Command Line Tools 的机器（比如本机）没有 XCTest 模块，
        // Testing.framework 也不在默认搜索路径里 —— 依赖它们就破坏了「零手工配置」。
        .executableTarget(
            name: "macai-spec",
            dependencies: ["MacAIKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
