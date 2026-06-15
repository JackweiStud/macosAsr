import Foundation

/// Backspace-and-retype injection state machine (TDD §4.4).
/// 方案 A：前缀差分注入——只退格/重打与上次不同的后缀，减少闪烁。
final class InjectionStateMachine {
    private let injector: TextInjecting
    private let injectionQueue = DispatchQueue(label: "com.macosasr.injection")
    private let queueKey = DispatchSpecificKey<Void>()
    /// 当前已注入但尚未提交（final）的 pending 文字
    private var pendingText: String = ""

    var pendingLen: Int {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return pendingText.count
        }
        return injectionQueue.sync { pendingText.count }
    }

    init(injector: TextInjecting) {
        self.injector = injector
        injectionQueue.setSpecific(key: queueKey, value: ())
    }

    func onPartial(_ text: String) {
        runOnInjectionQueue {
            self.applyPartial(text)
        }
    }

    func onFinal(_ text: String) {
        runOnInjectionQueue {
            self.applyFinal(text)
        }
    }

    func onFiltered() {
        runOnInjectionQueue {
            self.applyFiltered()
        }
    }

    func onSessionStopped() {
        runOnInjectionQueue {
            self.pendingText = ""
        }
    }

    func onUserInputInterrupted() {
        runOnInjectionQueue {
            self.applyUserInputInterrupted()
        }
    }

    private func runOnInjectionQueue(_ work: @escaping () -> Void) {
        injectionQueue.async(execute: work)
    }

    private func applyPartial(_ text: String) {
        let (backspaceCount, suffix) = diff(old: pendingText, new: text)
        if backspaceCount > 0 { injector.backspace(count: backspaceCount) }
        if !suffix.isEmpty { injector.typeText(suffix) }
        pendingText = text
    }

    private func applyFinal(_ text: String) {
        let (backspaceCount, suffix) = diff(old: pendingText, new: text)
        if backspaceCount > 0 { injector.backspace(count: backspaceCount) }
        if !suffix.isEmpty { injector.typeText(suffix) }
        pendingText = ""
        AppLogger.log("final len=\(text.count)")
    }

    private func applyFiltered() {
        if pendingLen > 0 { injector.backspace(count: pendingLen) }
        pendingText = ""
    }

    private func applyUserInputInterrupted() {
        pendingText = ""
        AppLogger.log("injection_pending_discarded_by_user_input")
    }

    // MARK: - 差分算法：返回 (需退格数, 需追加的新后缀)
    private func diff(old: String, new: String) -> (Int, String) {
        let oldChars = Array(old)
        let newChars = Array(new)
        var commonLen = 0
        while commonLen < oldChars.count && commonLen < newChars.count
            && oldChars[commonLen] == newChars[commonLen]
        {
            commonLen += 1
        }
        let backspaceCount = oldChars.count - commonLen
        let suffix = String(newChars[commonLen...])
        return (backspaceCount, suffix)
    }
}
