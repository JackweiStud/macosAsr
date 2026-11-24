import ApplicationServices
import Carbon.HIToolbox
import Cocoa

/// Optional local-only reader for active window title + text immediately before the cursor.
/// Disabled by default; strictly skips Secure Event Input, password fields, and credential managers.
enum ScreenContextReader {
    private static let maxWindowTitleChars = 60
    private static let maxCursorPrefixChars = 120
    private static let maxFallbackValueChars = 4000

    private static let blockedBundleIDs: Set<String> = [
        "com.macosasr.app",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.dashlane.Dashlane",
        "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop",
    ]

    private static let sensitiveKeywords = [
        "password", "passcode", "passphrase", "keychain", "1password", "bitwarden",
        "密码", "口令", "钥匙串", "私钥", "密钥",
    ]

    static func capture(from targetApp: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard !IsSecureEventInputEnabled() else { return nil }

        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        guard let app, !app.isTerminated else { return nil }
        if let bundleID = app.bundleIdentifier, blockedBundleIDs.contains(bundleID) {
            return nil
        }

        let appName = sanitize(app.localizedName ?? "", maxChars: 30)
        if containsSensitiveKeyword(appName) {
            return nil
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let windowTitle = readWindowTitle(from: axApp)
        if containsSensitiveKeyword(windowTitle) {
            return nil
        }

        let cursorPrefix = readSafeCursorPrefix(from: axApp)

        var parts: [String] = []
        if !appName.isEmpty || !windowTitle.isEmpty {
            let label = [appName, windowTitle].filter { !$0.isEmpty }.joined(separator: " - ")
            parts.append("当前窗口：\(label)")
        }
        if !cursorPrefix.isEmpty {
            parts.append("光标前文：\(cursorPrefix)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "；")
    }

    private static func readWindowTitle(from axApp: AXUIElement) -> String {
        var windowObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowObj) == .success,
              let windowObj, CFGetTypeID(windowObj) == AXUIElementGetTypeID()
        else { return "" }
        let axWindow = windowObj as! AXUIElement
        guard let title = copyStringAttribute(axWindow, kAXTitleAttribute as CFString) else { return "" }
        return sanitize(title, maxChars: maxWindowTitleChars)
    }

    private static func readSafeCursorPrefix(from axApp: AXUIElement) -> String {
        var focusedObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedObj) == .success,
              let focusedObj, CFGetTypeID(focusedObj) == AXUIElementGetTypeID()
        else { return "" }
        let element = focusedObj as! AXUIElement

        let role = copyStringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        if isSecureField(role: role, subrole: subrole) {
            return ""
        }

        // Prefer parameterized range lookup so large editor buffers are never copied in full.
        if let selectionRange = copySelectedRange(from: element) {
            let cursorLoc = max(0, selectionRange.location)
            if cursorLoc == 0 { return "" }
            let start = max(0, cursorLoc - maxCursorPrefixChars)
            let length = cursorLoc - start
            var range = CFRange(location: start, length: length)
            if let axRange = AXValueCreate(.cfRange, &range) {
                var sliceObj: CFTypeRef?
                let err = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    axRange,
                    &sliceObj
                )
                if err == .success, let slice = sliceObj as? String {
                    return sanitizeTail(slice, maxChars: maxCursorPrefixChars)
                }
            }
            if let value = copyStringAttribute(element, kAXValueAttribute as CFString),
               value.count <= maxFallbackValueChars
            {
                let prefix = String(value.prefix(cursorLoc))
                return sanitizeTail(prefix, maxChars: maxCursorPrefixChars)
            }
        }

        return ""
    }

    private static func isSecureField(role: String, subrole: String) -> Bool {
        if subrole == (kAXSecureTextFieldSubrole as String) { return true }
        let combined = "\(role) \(subrole)".lowercased()
        return combined.contains("secure") || combined.contains("password")
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func copySelectedRange(from element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        let axVal = ref as! AXValue
        guard AXValueGetType(axVal) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }
        return range
    }

    private static func containsSensitiveKeyword(_ text: String) -> Bool {
        let lower = text.lowercased()
        return sensitiveKeywords.contains { lower.contains($0) }
    }

    private static func sanitize(_ text: String, maxChars: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(maxChars))
    }

    private static func sanitizeTail(_ text: String, maxChars: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.suffix(maxChars))
    }
}
