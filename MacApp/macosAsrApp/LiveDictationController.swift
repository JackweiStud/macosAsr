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

    /// 直接开始听写；DaemonManager 内部负责等就绪。
    /// onFailure：daemon 启动失败或超时（已在主线程）
    func start(onFailure: @escaping (String) -> Void) {
        guard !isListening else { return }
        DaemonManager.shared.startSession { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.stateMachine.onSessionStopped()
                    self.isListening = true
                    AppLogger.log("live_dictation_started")
                case let .failure(error):
                    AppLogger.log("live_dictation_start_failed \(error.localizedDescription)", level: "ERROR")
                    onFailure(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        DaemonManager.shared.stopSession()
        isListening = false
        AppLogger.log("live_dictation_stop")
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
            DaemonManager.shared.notifySessionStoppedFromDaemon()
        case "error":
            AppLogger.log("daemon_error \(event.message ?? "?")", level: "ERROR")
        default:
            break
        }
    }
}
