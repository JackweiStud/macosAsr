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
    }

    func onFinal(_ text: String) {
        let (backspaceCount, suffix) = diff(old: pendingText, new: text)
        if backspaceCount > 0 { injector.backspace(count: backspaceCount) }
        if !suffix.isEmpty { injector.typeText(suffix) }
        pendingText = ""
        AppLogger.log("final len=\(text.count)")
    }

    func onFiltered() {
        if pendingLen > 0 { injector.backspace(count: pendingLen) }
        pendingText = ""
    }

    func onSessionStopped() {
        pendingText = ""
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
