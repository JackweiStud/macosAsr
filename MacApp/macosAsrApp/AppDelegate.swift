import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let injector = TextInjector()
    private lazy var stateMachine = InjectionStateMachine(injector: injector)
    private lazy var liveDictation = LiveDictationController(stateMachine: stateMachine)
    private var isRunningMock = false

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appDidBecomeActive() {
        guard injector.isAccessibilityTrusted else { return }
        AppLogger.log("accessibility trusted after activate")
    }

    private func logLaunchStatus() {
        let trusted = injector.isAccessibilityTrusted
        AppLogger.log(
            "macosAsrApp launched repo=\(ProjectPaths.repoRoot.path) "
                + "bundle=\(Bundle.main.bundlePath) trusted=\(trusted)"
        )
        if !trusted {
            AppLogger.log("accessibility not trusted — enable toggle then Quit and relaunch", level: "WARN")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(listening: false)
        AppLogger.log("status_item_created title=ASR")

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Start Live Dictation…",
                action: #selector(startLiveDictation),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Stop Live Dictation",
                action: #selector(stopLiveDictation),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Run Mock Injection Test…",
                action: #selector(runMockTest),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Open Accessibility Settings…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Quit",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        )
        for item in menu.items {
            item.target = self
        }
        statusItem?.menu = menu
    }

    private func updateStatusIcon(listening: Bool) {
        guard let button = statusItem?.button else {
            AppLogger.log("status_item_button_nil", level: "ERROR")
            return
        }
        button.title = listening ? "🎤 ASR●" : "🎤 ASR"
        button.image = nil
        button.contentTintColor = listening ? .systemRed : nil
    }

    @objc private func startLiveDictation() {
        guard requireAccessibility() else { return }

        // 记住当前最前台 App（备忘录等），对话框关闭后归还焦点
        let previousApp = NSWorkspace.shared.frontmostApplication

        let alert = NSAlert()
        alert.messageText = "Live 听写（P0d）"
        alert.informativeText = """
        1. 确认「备忘录」已打开并放置好光标
        2. 点「开始」后对着麦克风说话
        3. 完成后菜单栏选 Stop Live Dictation

        App 会自动启动 asr_daemon（若未运行）。
        """
        alert.addButton(withTitle: "开始")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 归还焦点给目标 App，让 CGEvent 打进正确窗口（macOS 14+ API）
        previousApp?.activate()

        updateStatusIcon(listening: true)
        liveDictation.toggle(from: statusItem?.button)
        // 若 daemon 启动失败，LiveDictationController 会弹错；此处延迟恢复图标
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.liveDictation.isActive else { return }
            self.updateStatusIcon(listening: false)
        }
    }

    @objc private func stopLiveDictation() {
        liveDictation.stopDictation()
        updateStatusIcon(listening: false)
    }

    @objc private func runMockTest() {
        guard !isRunningMock else { return }
        guard requireAccessibility() else { return }

        let alert = NSAlert()
        alert.messageText = "Mock 注入测试（P0c）"
        alert.informativeText = """
        1. 切换到「备忘录」并点击文本区放置光标
        2. 点「开始」后不要动键盘，约 1.5 秒内会依次写入 partial/final

        期望最终光标处为：你好，世界。
        """
        alert.addButton(withTitle: "开始")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isRunningMock = true
        AppLogger.log("user_started_mock_test")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            MockInjectionTest.run(stateMachine: self.stateMachine) { _, finalText in
                self.isRunningMock = false
                let done = NSAlert()
                done.messageText = "Mock 测试完成"
                done.informativeText = "请检查备忘录光标处是否为：\(finalText)"
                done.runModal()
            }
        }
    }

    private func requireAccessibility() -> Bool {
        if injector.isAccessibilityTrusted { return true }

        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        请按顺序操作（仅「出现在列表里」不够，开关必须是蓝色 ON）：

        1. 点「打开系统设置」
        2. 在 macosAsrApp 一行把开关拨到 ON（蓝色）
        3. 若开关已是 ON 仍失败：点列表下方「−」删除 macosAsrApp，再重新 launch 脚本
        4. 菜单栏 🎤 ASR → Quit（⌘Q），再运行 ./scripts/launch_macapp.sh
        5. 重新试 Mock 测试

        每次 ./scripts/build_macapp.sh 重建后，可能需重复步骤 2 或 3。

        App 路径：
        \(Bundle.main.bundlePath)
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
}
