import Foundation

/// Backspace-and-retype injection state machine (TDD §4.4).
/// 方案 A：前缀差分注入——只退格/重打与上次不同的后缀，减少闪烁。
final class InjectionStateMachine {
    private let injector: TextInjecting
    /// 当前已注入但尚未提交（final）的 pending 文字
    private(set) var pendingText: String = ""

    var pendingLen: Int { pendingText.count }

    init(injector: TextInjecting) {
        self.injector = injector
    }

    func onPartial(_ text: String) {
        let (backspaceCount, suffix) = diff(old: pendingText, new: text)
        if backspaceCount > 0 { injector.backspace(count: backspaceCount) }
        if !suffix.isEmpty { injector.typeText(suffix) }
        pendingText = text
        AppLogger.log("partial pending_len=\(pendingLen) bs=\(backspaceCount) append=\(suffix.count)")
    }

    func onFinal(_ text: String) {
        let (backspaceCount, suffix) = diff(old: pendingText, new: text)
        if backspaceCount > 0 { injector.backspace(count: backspaceCount) }
        if !suffix.isEmpty { injector.typeText(suffix) }
        pendingText = ""   // final 已提交，下一句 partial 从头开始
        AppLogger.log("final committed pending reset")
    }

    func onFiltered() {
        if pendingLen > 0 { injector.backspace(count: pendingLen) }
        pendingText = ""
        AppLogger.log("filtered cleared pending")
    }

    func onSessionStopped() {
        pendingText = ""
        AppLogger.log("session_stopped pending cleared")
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
