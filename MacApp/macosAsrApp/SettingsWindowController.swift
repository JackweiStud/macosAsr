import Cocoa

/// 设置窗口：识别语言（partial 间隔为代码默认值，不在此调整）。
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macosAsr Settings"
        window.center()
        super.init(window: window)
        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        reloadFromConfig()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        let label = NSTextField(labelWithString: "Recognition language:")
        label.translatesAutoresizingMaskIntoConstraints = false

        languagePopUp.translatesAutoresizingMaskIntoConstraints = false
        for lang in RecognitionLanguage.allCases {
            languagePopUp.addItem(withTitle: lang.displayName)
            languagePopUp.lastItem?.representedObject = lang.rawValue
        }
        languagePopUp.target = self
        languagePopUp.action = #selector(languageChanged(_:))

        let hint = NSTextField(wrappingLabelWithString: "Language changes apply the next time you start dictation.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(label)
        contentView.addSubview(languagePopUp)
        contentView.addSubview(hint)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            languagePopUp.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            languagePopUp.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            languagePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            hint.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 20),
            hint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
        ])
    }

    private func reloadFromConfig() {
        let current = ConfigManager.shared.language
        for i in 0 ..< languagePopUp.numberOfItems {
            if let value = languagePopUp.item(at: i)?.representedObject as? String, value == current {
                languagePopUp.selectItem(at: i)
                return
            }
        }
        languagePopUp.selectItem(at: 0)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let language = sender.selectedItem?.representedObject as? String else { return }
        do {
            try ConfigManager.shared.saveLanguage(language)
        } catch {
            AppLogger.log("config_save_failed \(error.localizedDescription)", level: "ERROR")
            reloadFromConfig()
        }
    }
}
