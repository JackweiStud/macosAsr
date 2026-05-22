import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let injector = TextInjector()
    private lazy var stateMachine = InjectionStateMachine(injector: injector)
    private lazy var liveDictation = LiveDictationController(stateMachine: stateMachine)

    private var startStopMenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?
    private var preDictationApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        logLaunchStatus()
        if !injector.isAccessibilityTrusted {
            injector.registerForAccessibilityPrompt()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // 监听 daemon 状态，驱动菜单栏 UI
        DaemonManager.shared.onStateChange = { [weak self] state in
            self?.applyDaemonState(state)
        }

        // 启动后立即 warm daemon（不再等用户点 Start）
        DaemonManager.shared.warmUp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        DaemonManager.shared.shutdown()
    }

    @objc private func appDidBecomeActive() {
        // 不在每次激活时写日志；启动时 logLaunchStatus 已记录 trusted 状态
    }

    private func logLaunchStatus() {
        let trusted = injector.isAccessibilityTrusted
        AppLogger.log("launch trusted=\(trusted) repo=\(ProjectPaths.repoRoot.path)")
        if !trusted {
            AppLogger.log("accessibility not trusted — enable toggle then Quit and relaunch", level: "WARN")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()

        let statusItemEntry = NSMenuItem(title: "状态：初始化…", action: nil, keyEquivalent: "")
        statusItemEntry.isEnabled = false
        menu.addItem(statusItemEntry)
        statusMenuItem = statusItemEntry

        menu.addItem(NSMenuItem.separator())

        let startStop = NSMenuItem(
            title: "Start Live Dictation",
            action: #selector(toggleLiveDictation),
            keyEquivalent: ""
        )
        menu.addItem(startStop)
        startStopMenuItem = startStop

        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Open Accessibility Settings…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
        )
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        for item in menu.items where item.action != nil && item !== quitItem {
            item.target = self
        }
        statusItem?.menu = menu

        applyDaemonState(.idle)
    }

    // MARK: - 菜单栏四态显示

    private func resetStatusBarButtonStyle() {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = NSAttributedString()
        button.image = nil
        button.imagePosition = .noImage
        button.contentTintColor = nil
    }

    private func applyDaemonState(_ state: DaemonState) {
        guard let button = statusItem?.button else { return }
        resetStatusBarButtonStyle()

        switch state {
        case .idle:
            button.title = "⏳ ASR"
            statusMenuItem?.title = "状态：未启动"
            startStopMenuItem?.title = "Start Live Dictation"
            startStopMenuItem?.isEnabled = false
        case .loading:
            button.title = "⏳ ASR"
            statusMenuItem?.title = "状态：加载模型中…"
            startStopMenuItem?.title = "Start Live Dictation（加载中…）"
            startStopMenuItem?.isEnabled = false
        case .ready:
            button.title = "🎤 ASR"
            statusMenuItem?.title = "状态：就绪"
            startStopMenuItem?.title = "Start Live Dictation"
            startStopMenuItem?.isEnabled = true
        case .listening:
            // 绿点用 emoji；文字交给系统着色（深色菜单栏自动变白）
            button.title = "🟢 状态：听写中…"
            statusMenuItem?.title = "状态：听写中…"
            startStopMenuItem?.title = "Stop Live Dictation"
            startStopMenuItem?.isEnabled = true
        case let .error(msg):
            button.title = "⚠️ ASR"
            statusMenuItem?.title = "状态：错误（点击查看）"
            startStopMenuItem?.title = "Start Live Dictation"
            startStopMenuItem?.isEnabled = false
            AppLogger.log("daemon_error_state \(msg)", level: "ERROR")
        }
    }

    // MARK: - 菜单动作

    @objc private func toggleLiveDictation() {
        guard requireAccessibility() else { return }

        switch DaemonManager.shared.state {
        case .listening:
            liveDictation.stop()
        case .ready:
            preDictationApp = NSWorkspace.shared.frontmostApplication
            liveDictation.start { [weak self] errorMsg in
                self?.showError("无法启动听写", text: errorMsg)
            }
            // 把焦点还给目标 App，让 CGEvent 注入对（macOS 14+ API）
            preDictationApp?.activate()
        default:
            // loading/idle/error：菜单本应已禁用，理论上走不到
            return
        }
    }

    private func requireAccessibility() -> Bool {
        if injector.isAccessibilityTrusted { return true }

        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        请按顺序操作（开关必须是蓝色 ON）：

        1. 点「打开系统设置」
        2. 找到 macosAsrApp，把开关拨到 ON
        3. 若已 ON 仍失败：删掉 macosAsrApp 条目，重启 App，重新授权
        4. 菜单栏 ASR → Quit（⌘Q），再启动 App
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
        return false
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApplication(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }

    private func showError(_ title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }
}
