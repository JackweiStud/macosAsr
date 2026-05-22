import ApplicationServices
import Cocoa

/// Simulated keyboard input via CGEvent (TDD §4.3). Requires Accessibility permission.
protocol TextInjecting: AnyObject {
    func backspace(count: Int)
    func typeText(_ text: String)
}

final class TextInjector: TextInjecting {
    private let backspaceKeyCode: CGKeyCode = 0x33 // kVK_Delete

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 首次启动时调用一次，让系统把本 App 加入辅助功能列表（会弹系统对话框）。
    func registerForAccessibilityPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func backspace(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0 ..< count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(400)
        }
    }

    func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for char in text {
            var utf16 = Array(String(char).utf16)
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(400)
        }
    }
}
