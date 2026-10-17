import Cocoa

/// P0d: menu-triggered live dictation — Daemon partial/final → InjectionStateMachine.
final class LiveDictationController {
    private let stateMachine: InjectionStateMachine
    private var onStartFailure: ((String) -> Void)?

    init(stateMachine: InjectionStateMachine) {
        self.stateMachine = stateMachine
        DaemonManager.shared.onInjectionSessionStarted = { [weak stateMachine] sessionID, resumedCutoff in
            stateMachine?.onSessionStarted(sessionID, discardBefore: resumedCutoff ?? 0)
        }
        DaemonManager.shared.finishInjectionSession = { [weak stateMachine] sessionID, completion in
            guard let stateMachine else { completion(); return }
            stateMachine.onSessionStopped(sessionID, completion: completion)
        }
        DaemonManager.shared.cancelInjection = { [weak stateMachine] in
            if let sessionID = stateMachine?.onUserInputInterrupted() {
                stateMachine?.onSessionStopped(sessionID)
            }
        }
        DaemonManager.shared.onSessionFailure = { [weak self] message in
            guard let self else { return }
            AppLogger.log("live_dictation_failed \(message)", level: "ERROR")
            let onFailure = self.onStartFailure
            self.onStartFailure = nil
            onFailure?(message)
        }
        DaemonManager.shared.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    var isActive: Bool { DaemonManager.shared.state == .listening }

    func start(onFailure: @escaping (String) -> Void) {
        onStartFailure = onFailure
        DaemonManager.shared.startSession()
    }

    func stop() {
        onStartFailure = nil
        DaemonManager.shared.stopSession()
        AppLogger.log("live_dictation_stop_requested")
    }

    func notifyUserInputInterrupted() {
        // Called from the event tap: cancel queued/in-flight writes before main-thread IPC.
        let timestamp = Date().timeIntervalSince1970
        guard let sessionID = stateMachine.onUserInputInterrupted(at: timestamp) else { return }
        DispatchQueue.main.async {
            DaemonManager.shared.discardCurrentUtterance(sessionID: sessionID, before: timestamp)
        }
    }

    private func handle(_ event: DaemonEvent) {
        switch event.type {
        case "partial":
            if let text = event.text, !text.isEmpty, let utterance = event.utterance {
                stateMachine.onPartial(text, utterance: utterance)
            }
        case "final":
            if let text = event.text, !text.isEmpty, let utterance = event.utterance {
                stateMachine.onFinal(text, utterance: utterance)
            }
        case "filtered":
            if let utterance = event.utterance {
                stateMachine.onFiltered(utterance: utterance)
            }
        case "warning":
            AppLogger.log("daemon_warning \(event.message ?? "?")", level: "WARN")
        case "error":
            AppLogger.log("daemon_error \(event.message ?? "?")", level: "ERROR")
        default:
            break
        }
    }

}
