import Cocoa

/// P0d: menu-triggered live dictation — Daemon partial/final → InjectionStateMachine.
final class LiveDictationController {
    private let stateMachine: InjectionStateMachine
    private var isListening = false

    init(stateMachine: InjectionStateMachine) {
        self.stateMachine = stateMachine
        DaemonManager.shared.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    var isActive: Bool { isListening }

    func toggle(from view: NSView?) {
        if isListening {
            stop()
        } else {
            start(from: view)
        }
    }

    private func start(from view: NSView?) {
        DaemonManager.shared.ensureDaemonReady { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.stateMachine.onSessionStopped()
                self.isListening = true
                DaemonManager.shared.sendSessionStart()
                AppLogger.log("live_dictation_started")
            case let .failure(error):
                AppLogger.log("live_dictation_start_failed \(error.localizedDescription)", level: "ERROR")
                self.showAlert(on: view, title: "无法启动 Daemon", text: error.localizedDescription)
            }
        }
    }

    func stopDictation() {
        stop()
    }

    private func stop() {
        guard isListening else { return }
        DaemonManager.shared.sendSessionStop()
        isListening = false
        AppLogger.log("live_dictation_stop_sent")
    }

    private func handle(_ event: DaemonEvent) {
        switch event.type {
        case "partial":
            if let text = event.text, !text.isEmpty {
                stateMachine.onPartial(text)
            }
        case "final":
            if let text = event.text, !text.isEmpty {
                stateMachine.onFinal(text)
            }
        case "filtered":
            stateMachine.onFiltered()
        case "session_stopped":
            isListening = false
            stateMachine.onSessionStopped()
            AppLogger.log("live_dictation_session_stopped")
        case "error":
            AppLogger.log("daemon_error \(event.message ?? "?")", level: "ERROR")
        default:
            break
        }
    }

    private func showAlert(on view: NSView?, title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
