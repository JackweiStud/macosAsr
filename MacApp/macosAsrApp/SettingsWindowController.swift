import Cocoa

/// 设置窗口：识别语言与开发者向高级听写参数。
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let asrModelPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let vadEndSilencePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let partialIntervalPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 310),
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

        let advancedTitle = NSTextField(labelWithString: "Advanced dictation settings")
        advancedTitle.font = NSFont.boldSystemFont(ofSize: 13)
        advancedTitle.translatesAutoresizingMaskIntoConstraints = false

        let modelLabel = NSTextField(labelWithString: "ASR model:")
        modelLabel.translatesAutoresizingMaskIntoConstraints = false

        asrModelPopUp.translatesAutoresizingMaskIntoConstraints = false
        for preset in AsrModelPreset.allCases {
            asrModelPopUp.addItem(withTitle: preset.displayName)
            asrModelPopUp.lastItem?.representedObject = preset.rawValue
        }
        asrModelPopUp.target = self
        asrModelPopUp.action = #selector(advancedSettingChanged(_:))

        let vadLabel = NSTextField(labelWithString: "Sentence end wait:")
        vadLabel.translatesAutoresizingMaskIntoConstraints = false

        vadEndSilencePopUp.translatesAutoresizingMaskIntoConstraints = false
        for preset in VadEndSilencePreset.allCases {
            vadEndSilencePopUp.addItem(withTitle: preset.displayName)
            vadEndSilencePopUp.lastItem?.representedObject = preset.rawValue
        }
        vadEndSilencePopUp.target = self
        vadEndSilencePopUp.action = #selector(advancedSettingChanged(_:))

        let partialLabel = NSTextField(labelWithString: "Live text refresh:")
        partialLabel.translatesAutoresizingMaskIntoConstraints = false

        partialIntervalPopUp.translatesAutoresizingMaskIntoConstraints = false
        for preset in PartialIntervalPreset.allCases {
            partialIntervalPopUp.addItem(withTitle: preset.displayName)
            partialIntervalPopUp.lastItem?.representedObject = preset.rawValue
        }
        partialIntervalPopUp.target = self
        partialIntervalPopUp.action = #selector(advancedSettingChanged(_:))

        let hint = NSTextField(wrappingLabelWithString: "Changes apply the next time the app starts the ASR daemon. Restart the app if it is already ready.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(label)
        contentView.addSubview(languagePopUp)
        contentView.addSubview(advancedTitle)
        contentView.addSubview(modelLabel)
        contentView.addSubview(asrModelPopUp)
        contentView.addSubview(vadLabel)
        contentView.addSubview(vadEndSilencePopUp)
        contentView.addSubview(partialLabel)
        contentView.addSubview(partialIntervalPopUp)
        contentView.addSubview(hint)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            label.widthAnchor.constraint(equalToConstant: 145),

            languagePopUp.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            languagePopUp.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 16),
            languagePopUp.widthAnchor.constraint(equalToConstant: 200),

            advancedTitle.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 28),
            advancedTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            modelLabel.topAnchor.constraint(equalTo: advancedTitle.bottomAnchor, constant: 18),
            modelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            modelLabel.widthAnchor.constraint(equalTo: label.widthAnchor),

            asrModelPopUp.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            asrModelPopUp.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 16),
            asrModelPopUp.widthAnchor.constraint(equalToConstant: 260),

            vadLabel.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 18),
            vadLabel.leadingAnchor.constraint(equalTo: modelLabel.leadingAnchor),
            vadLabel.widthAnchor.constraint(equalTo: label.widthAnchor),

            vadEndSilencePopUp.centerYAnchor.constraint(equalTo: vadLabel.centerYAnchor),
            vadEndSilencePopUp.leadingAnchor.constraint(equalTo: asrModelPopUp.leadingAnchor),
            vadEndSilencePopUp.widthAnchor.constraint(equalTo: asrModelPopUp.widthAnchor),

            partialLabel.topAnchor.constraint(equalTo: vadLabel.bottomAnchor, constant: 18),
            partialLabel.leadingAnchor.constraint(equalTo: vadLabel.leadingAnchor),
            partialLabel.widthAnchor.constraint(equalTo: label.widthAnchor),

            partialIntervalPopUp.centerYAnchor.constraint(equalTo: partialLabel.centerYAnchor),
            partialIntervalPopUp.leadingAnchor.constraint(equalTo: vadEndSilencePopUp.leadingAnchor),
            partialIntervalPopUp.widthAnchor.constraint(equalTo: asrModelPopUp.widthAnchor),

            hint.topAnchor.constraint(equalTo: partialLabel.bottomAnchor, constant: 22),
            hint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
        ])
    }

    private func reloadFromConfig() {
        let current = ConfigManager.shared.language
        var selectedLanguage = false
        for i in 0 ..< languagePopUp.numberOfItems {
            if let value = languagePopUp.item(at: i)?.representedObject as? String, value == current {
                languagePopUp.selectItem(at: i)
                selectedLanguage = true
                break
            }
        }
        if !selectedLanguage {
            languagePopUp.selectItem(at: 0)
        }

        selectPopup(asrModelPopUp, value: ConfigManager.shared.asrModel)
        selectPopup(vadEndSilencePopUp, value: ConfigManager.shared.vadEndSilenceSeconds)
        selectPopup(partialIntervalPopUp, value: ConfigManager.shared.partialIntervalSeconds)
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

    @objc private func advancedSettingChanged(_ sender: NSPopUpButton) {
        guard
            let asrModel = asrModelPopUp.selectedItem?.representedObject as? String,
            let partial = partialIntervalPopUp.selectedItem?.representedObject as? Double,
            let vad = vadEndSilencePopUp.selectedItem?.representedObject as? Double
        else { return }
        do {
            try ConfigManager.shared.saveAdvancedDictationSettings(
                asrModel: asrModel,
                partialIntervalSeconds: partial,
                vadEndSilenceSeconds: vad
            )
        } catch {
            AppLogger.log("config_save_failed \(error.localizedDescription)", level: "ERROR")
            reloadFromConfig()
        }
    }

    private func selectPopup(_ popup: NSPopUpButton, value: Double) {
        for i in 0 ..< popup.numberOfItems {
            if let itemValue = popup.item(at: i)?.representedObject as? Double,
               abs(itemValue - value) < 0.0001 {
                popup.selectItem(at: i)
                return
            }
        }
        popup.selectItem(at: 0)
    }

    private func selectPopup(_ popup: NSPopUpButton, value: String) {
        for i in 0 ..< popup.numberOfItems {
            if let itemValue = popup.item(at: i)?.representedObject as? String,
               itemValue == value {
                popup.selectItem(at: i)
                return
            }
        }
        popup.selectItem(at: 0)
    }
}
