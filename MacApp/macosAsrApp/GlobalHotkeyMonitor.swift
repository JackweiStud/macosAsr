import ApplicationServices
import Cocoa

/// Global ⌥Z toggle for Start/Stop live dictation (session-level event tap).
final class GlobalHotkeyMonitor {
    var onTrigger: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    private var lastTriggerTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.25

    /// ⌥ 是必需的；这些是「不允许同时按下」的其它修饰键。
    private static let forbiddenCGModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]
    private static let zKeyCode: Int64 = 6 // kVK_ANSI_Z

    private(set) var isRunning = false

    var isInputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    func start() {
        stop()
        guard canMonitorKeyEvents else {
            isRunning = false
            AppLogger.log("hotkey_monitor_unavailable — grant Input Monitoring for global ⌥Z", level: "WARN")
            return
        }
        startEventTap()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop = tapRunLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        tapThread = nil
        tapRunLoop = nil
        runLoopSource = nil
        eventTap = nil
        isRunning = false
    }

    func refresh() {
        start()
    }

    @discardableResult
    func requestInputMonitoringAccess() -> Bool {
        if isInputMonitoringGranted { return true }
        return CGRequestListenEventAccess()
    }

    private var canMonitorKeyEvents: Bool {
        isInputMonitoringGranted || AXIsProcessTrusted()
    }

    private func startEventTap() {
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        // defaultTap：匹配时 return nil 吞掉事件，避免 ⌥Z 在文本框里输出 Ω。
        // 需要辅助功能（AX）权限；本 App 已要求。
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            isRunning = false
            AppLogger.log("hotkey_event_tap_create_failed", level: "ERROR")
            return
        }

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            isRunning = false
            AppLogger.log("hotkey_event_tap_source_failed", level: "ERROR")
            eventTap = nil
            return
        }
        runLoopSource = source

        let thread = Thread { [weak self] in
            guard let self else { return }
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(self.tapRunLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                AppLogger.log("hotkey_event_tap_not_enabled", level: "ERROR")
                self.isRunning = false
                return
            }
            self.isRunning = true
            AppLogger.log("hotkey_event_tap_started ⌥Z")
            CFRunLoopRun()
        }
        thread.name = "GlobalHotkeyMonitor"
        thread.start()
        tapThread = thread
    }

    /// keyDown：满足 ⌥Z 时触发回调并吞事件；keyUp：仅吞事件，避免 ⌥+Z 的 up 抵达前台 App。
    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard matchesHotkey(event) else { return false }

        if type == .keyDown {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTriggerTime >= debounceInterval {
                lastTriggerTime = now
                DispatchQueue.main.async { [weak self] in
                    self?.onTrigger?()
                }
            }
        }
        return true
    }

    private func matchesHotkey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        guard flags.contains(.maskAlternate) else { return false }
        guard flags.intersection(Self.forbiddenCGModifiers).isEmpty else { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        return keyCode == Self.zKeyCode
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }

        let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp {
            if monitor.handleEvent(type: type, event: event) {
                return nil // 吞掉 ⌥Z，防止文本框出现 Ω
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
