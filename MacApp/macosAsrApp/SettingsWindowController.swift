import Cocoa

/// 设置窗口：识别语言、高级听写参数、自定义热词词典与可选屏幕上下文。
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    static let shared = SettingsWindowController()

    private let languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let asrModelPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let vadEndSilencePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let partialIntervalPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hotwordsTextView = NSTextView(frame: .zero)
    private let hotwordsStatusLabel = NSTextField(labelWithString: "")
    private let oralPolishPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let screenContextCheckbox = NSButton(
        checkboxWithTitle: "Read active window & cursor context (optional)",
        target: nil,
        action: nil
    )
    private let hudCheckbox = NSButton(
        checkboxWithTitle: "Show floating status HUD capsule while dictating",
        target: nil,
        action: nil
    )

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 646),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macosAsr Settings"
        window.center()
        super.init(window: window)
        window.delegate = self
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

    func windowWillClose(_ notification: Notification) {
        saveHotwordsIfChanged(showStatus: false)
    }

    func textDidEndEditing(_ notification: Notification) {
        saveHotwordsIfChanged(showStatus: true)
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

        let hint = NSTextField(wrappingLabelWithString: "Sentence end wait and live text refresh apply immediately. Changing the ASR model requires restarting the app.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let contextTitle = NSTextField(labelWithString: "Accuracy & context")
        contextTitle.font = NSFont.boldSystemFont(ofSize: 13)
        contextTitle.translatesAutoresizingMaskIntoConstraints = false

        let hotwordsLabel = NSTextField(labelWithString: "Custom hotwords / terms (comma or newline separated):")
        hotwordsLabel.font = NSFont.systemFont(ofSize: 12)
        hotwordsLabel.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        hotwordsTextView.isEditable = true
        hotwordsTextView.isSelectable = true
        hotwordsTextView.isRichText = false
        hotwordsTextView.allowsUndo = true
        hotwordsTextView.font = NSFont.systemFont(ofSize: 12)
        hotwordsTextView.isAutomaticQuoteSubstitutionEnabled = false
        hotwordsTextView.isAutomaticDashSubstitutionEnabled = false
        hotwordsTextView.isAutomaticTextReplacementEnabled = false
        hotwordsTextView.textContainerInset = NSSize(width: 4, height: 6)
        hotwordsTextView.autoresizingMask = [.width]
        hotwordsTextView.delegate = self
        scrollView.documentView = hotwordsTextView

        let applyHotwordsButton = NSButton(title: "Save & Apply", target: self, action: #selector(applyHotwordsClicked))
        applyHotwordsButton.bezelStyle = .rounded
        applyHotwordsButton.translatesAutoresizingMaskIntoConstraints = false

        let resetHotwordsButton = NSButton(title: "Reset Defaults", target: self, action: #selector(resetHotwordsClicked))
        resetHotwordsButton.bezelStyle = .rounded
        resetHotwordsButton.translatesAutoresizingMaskIntoConstraints = false

        hotwordsStatusLabel.font = NSFont.systemFont(ofSize: 11)
        hotwordsStatusLabel.textColor = .secondaryLabelColor
        hotwordsStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let oralPolishLabel = NSTextField(labelWithString: "Oral polish:")
        oralPolishLabel.translatesAutoresizingMaskIntoConstraints = false

        oralPolishPopUp.translatesAutoresizingMaskIntoConstraints = false
        for preset in OralPolishPreset.allCases {
            oralPolishPopUp.addItem(withTitle: preset.displayName)
            oralPolishPopUp.lastItem?.representedObject = preset.rawValue
        }
        oralPolishPopUp.target = self
        oralPolishPopUp.action = #selector(oralPolishChanged(_:))

        let oralPolishHint = NSTextField(
            wrappingLabelWithString: "Applies at sentence end to clean fillers, stutters, and punctuation while strictly keeping all English terms and numbers. Off uses 0 extra RAM; Local LLM loads ~1 GB on demand and frees it when turned off."
        )
        oralPolishHint.font = NSFont.systemFont(ofSize: 11)
        oralPolishHint.textColor = .secondaryLabelColor
        oralPolishHint.translatesAutoresizingMaskIntoConstraints = false

        screenContextCheckbox.target = self
        screenContextCheckbox.action = #selector(screenContextToggled(_:))
        screenContextCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let screenContextHint = NSTextField(
            wrappingLabelWithString: "Off by default. When enabled, reads active window title and up to 120 chars before the cursor at ⌥Z start (local only, never logged, automatically skips password fields)."
        )
        screenContextHint.font = NSFont.systemFont(ofSize: 11)
        screenContextHint.textColor = .secondaryLabelColor
        screenContextHint.translatesAutoresizingMaskIntoConstraints = false

        hudCheckbox.target = self
        hudCheckbox.action = #selector(hudToggled(_:))
        hudCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let hudHint = NSTextField(
            wrappingLabelWithString: "Non-activating obsidian glass capsule showing live mic waveform, polishing status, and calibration progress. Drag to move anywhere (double-click to recenter); never steals focus."
        )
        hudHint.font = NSFont.systemFont(ofSize: 11)
        hudHint.textColor = .secondaryLabelColor
        hudHint.translatesAutoresizingMaskIntoConstraints = false

        for view in [
            label, languagePopUp, advancedTitle, modelLabel, asrModelPopUp,
            vadLabel, vadEndSilencePopUp, partialLabel, partialIntervalPopUp, hint,
            contextTitle, hotwordsLabel, scrollView, applyHotwordsButton,
            resetHotwordsButton, hotwordsStatusLabel, oralPolishLabel, oralPolishPopUp,
            oralPolishHint, screenContextCheckbox, screenContextHint, hudCheckbox, hudHint,
        ] {
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            label.widthAnchor.constraint(equalToConstant: 145),

            languagePopUp.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            languagePopUp.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 16),
            languagePopUp.widthAnchor.constraint(equalToConstant: 200),

            advancedTitle.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 22),
            advancedTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            modelLabel.topAnchor.constraint(equalTo: advancedTitle.bottomAnchor, constant: 14),
            modelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            modelLabel.widthAnchor.constraint(equalTo: label.widthAnchor),

            asrModelPopUp.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            asrModelPopUp.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 16),
            asrModelPopUp.widthAnchor.constraint(equalToConstant: 260),

            vadLabel.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 14),
            vadLabel.leadingAnchor.constraint(equalTo: modelLabel.leadingAnchor),
            vadLabel.widthAnchor.constraint(equalTo: label.widthAnchor),

            vadEndSilencePopUp.centerYAnchor.constraint(equalTo: vadLabel.centerYAnchor),
            vadEndSilencePopUp.leadingAnchor.constraint(equalTo: asrModelPopUp.leadingAnchor),
            vadEndSilencePopUp.widthAnchor.constraint(equalTo: asrModelPopUp.widthAnchor),

            partialLabel.topAnchor.constraint(equalTo: vadLabel.bottomAnchor, constant: 14),
            partialLabel.leadingAnchor.constraint(equalTo: vadLabel.leadingAnchor),
            partialLabel.widthAnchor.constraint(equalTo: label.widthAnchor),

            partialIntervalPopUp.centerYAnchor.constraint(equalTo: partialLabel.centerYAnchor),
            partialIntervalPopUp.leadingAnchor.constraint(equalTo: vadEndSilencePopUp.leadingAnchor),
            partialIntervalPopUp.widthAnchor.constraint(equalTo: asrModelPopUp.widthAnchor),

            hint.topAnchor.constraint(equalTo: partialLabel.bottomAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            contextTitle.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 20),
            contextTitle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            hotwordsLabel.topAnchor.constraint(equalTo: contextTitle.bottomAnchor, constant: 10),
            hotwordsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            hotwordsLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            scrollView.topAnchor.constraint(equalTo: hotwordsLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            scrollView.heightAnchor.constraint(equalToConstant: 82),

            applyHotwordsButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            applyHotwordsButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            resetHotwordsButton.centerYAnchor.constraint(equalTo: applyHotwordsButton.centerYAnchor),
            resetHotwordsButton.leadingAnchor.constraint(equalTo: applyHotwordsButton.trailingAnchor, constant: 8),

            hotwordsStatusLabel.centerYAnchor.constraint(equalTo: applyHotwordsButton.centerYAnchor),
            hotwordsStatusLabel.leadingAnchor.constraint(equalTo: resetHotwordsButton.trailingAnchor, constant: 12),
            hotwordsStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),

            oralPolishLabel.topAnchor.constraint(equalTo: applyHotwordsButton.bottomAnchor, constant: 16),
            oralPolishLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            oralPolishLabel.widthAnchor.constraint(equalTo: label.widthAnchor),

            oralPolishPopUp.centerYAnchor.constraint(equalTo: oralPolishLabel.centerYAnchor),
            oralPolishPopUp.leadingAnchor.constraint(equalTo: asrModelPopUp.leadingAnchor),
            oralPolishPopUp.widthAnchor.constraint(equalTo: asrModelPopUp.widthAnchor),

            oralPolishHint.topAnchor.constraint(equalTo: oralPolishLabel.bottomAnchor, constant: 6),
            oralPolishHint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            oralPolishHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            screenContextCheckbox.topAnchor.constraint(equalTo: oralPolishHint.bottomAnchor, constant: 14),
            screenContextCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            screenContextHint.topAnchor.constraint(equalTo: screenContextCheckbox.bottomAnchor, constant: 4),
            screenContextHint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 42),
            screenContextHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            hudCheckbox.topAnchor.constraint(equalTo: screenContextHint.bottomAnchor, constant: 12),
            hudCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),

            hudHint.topAnchor.constraint(equalTo: hudCheckbox.bottomAnchor, constant: 4),
            hudHint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 42),
            hudHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
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
        hotwordsTextView.string = ConfigManager.shared.customHotwords
        hotwordsStatusLabel.stringValue = "Applies immediately without restart"
        selectPopup(
            oralPolishPopUp,
            value: ConfigManager.shared.oralPolishEnabled ? OralPolishPreset.localLLM.rawValue : OralPolishPreset.off.rawValue
        )
        screenContextCheckbox.state = ConfigManager.shared.screenContextEnabled ? .on : .off
        hudCheckbox.state = ConfigManager.shared.hudEnabled ? .on : .off
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
            DaemonManager.shared.pushRuntimeDictationSettings()
        } catch {
            AppLogger.log("config_save_failed \(error.localizedDescription)", level: "ERROR")
            reloadFromConfig()
        }
    }

    @objc private func applyHotwordsClicked() {
        saveHotwords(hotwordsTextView.string, showStatus: true)
    }

    @objc private func resetHotwordsClicked() {
        hotwordsTextView.string = AppConfig.defaultCustomHotwords
        saveHotwords(AppConfig.defaultCustomHotwords, showStatus: true)
    }

    @objc private func oralPolishChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let preset = OralPolishPreset(rawValue: raw)
        else { return }
        do {
            try ConfigManager.shared.saveOralPolishEnabled(preset.isEnabled)
            DaemonManager.shared.pushRuntimeDictationSettings()
        } catch {
            AppLogger.log("config_save_failed \(error.localizedDescription)", level: "ERROR")
            reloadFromConfig()
        }
    }

    @objc private func screenContextToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            try ConfigManager.shared.saveScreenContextEnabled(enabled)
        } catch {
            AppLogger.log("config_save_failed \(error.localizedDescription)", level: "ERROR")
            reloadFromConfig()
        }
    }

    @objc private func hudToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            try ConfigManager.shared.saveHudEnabled(enabled)
            FloatingHUDController.shared.setEnabled(enabled)
        } catch {
            AppLogger.log("config_save_failed \(error.localizedDescription)", level: "ERROR")
            reloadFromConfig()
        }
    }

    private func saveHotwordsIfChanged(showStatus: Bool) {
        let trimmed = hotwordsTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != ConfigManager.shared.customHotwords else { return }
        saveHotwords(trimmed, showStatus: showStatus)
    }

    private func saveHotwords(_ raw: String, showStatus: Bool) {
        do {
            try ConfigManager.shared.saveCustomHotwords(raw)
            DaemonManager.shared.pushRuntimeDictationSettings()
            if showStatus {
                hotwordsStatusLabel.stringValue = "Saved & applied immediately"
            }
        } catch {
            AppLogger.log("config_save_failed \(error.localizedDescription)", level: "ERROR")
            if showStatus {
                hotwordsStatusLabel.stringValue = "Save failed"
            }
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
