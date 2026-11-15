import Foundation
import MacAIKit

// 薄入口：一切逻辑都在 MacAIKit 里（可单测），这里只做线程编排与退出码传递。
//
// ⚠️ 为什么要在**后台线程**跑 CLI、主线程泵 runloop：
// 系统框架里有的 API（Translation 的 LanguageAvailability/TranslationSession）会把续体
// 回投到**主队列** —— 若主线程正阻塞在信号量上等它们，就是死锁（实测：`macai translate --status`
// 永不返回）。而 AVSpeechSynthesizer 的 write 回调又必须靠**泵 runloop** 才会触发。
// 两者同时满足的唯一稳定形态：主线程泵 runloop，业务跑在后台线程。
private let done = DispatchSemaphore(value: 0)
private var exitCode: Int32 = ExitCode.runtime

let worker = Thread {
    exitCode = CLI.run(Array(CommandLine.arguments.dropFirst()))
    done.signal()
}
worker.stackSize = 8 << 20
worker.start()

while done.wait(timeout: .now() + 0.05) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}

exit(exitCode)
