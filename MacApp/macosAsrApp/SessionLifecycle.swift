import Foundation

/// Serializes user intent, daemon acknowledgements, and the final keyboard-write barrier.
/// All entry points and callbacks run on the main thread; socket write success is not an ack.
final class SessionLifecycle {
    enum Phase: Equatable {
        case ready
        case starting
        case listening(String)
        case stopping(String)
        case failed(String)
    }
    enum Command: String { case start = "session_start", stop = "session_stop" }
    typealias CommandSender = (Command, @escaping (Result<Void, Error>) -> Void) -> Void

    private let sendCommand: CommandSender
    private let beginInjection: (String, TimeInterval?) -> Void
    private let finishInjection: (String, @escaping () -> Void) -> Void
    private let cancelInjection: () -> Void
    private var epoch: UInt64 = 0
    private var finishingSessionID: String?
    private var retiredSessionIDs: [String] = []

    private(set) var phase: Phase = .ready
    private(set) var desiredListening = false
    var onChange: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onCommandFailure: ((String) -> Void)?

    init(sendCommand: @escaping CommandSender,
         beginInjection: @escaping (String, TimeInterval?) -> Void,
         finishInjection: @escaping (String, @escaping () -> Void) -> Void,
         cancelInjection: @escaping () -> Void) {
        self.sendCommand = sendCommand
        self.beginInjection = beginInjection
        self.finishInjection = finishInjection
        self.cancelInjection = cancelInjection
    }

    func setDesiredListening(_ desired: Bool) {
        precondition(Thread.isMainThread)
        guard case .failed = phase else {
            desiredListening = desired
            reconcile()
            onChange?()
            return
        }
    }

    @discardableResult
    func sessionStarted(_ sessionID: String, resumedAt: TimeInterval? = nil) -> Bool {
        precondition(Thread.isMainThread)
        guard !sessionID.isEmpty, (resumedAt != nil || !retiredSessionIDs.contains(sessionID)), phase == .starting else { return false }
        if let resumedAt, (!resumedAt.isFinite || resumedAt <= 0) { return false }
        if resumedAt != nil { retiredSessionIDs.removeAll { $0 == sessionID } }
        beginInjection(sessionID, resumedAt)
        phase = .listening(sessionID)
        reconcile()
        onChange?()
        return true
    }

    func sessionStopped(_ sessionID: String) {
        precondition(Thread.isMainThread)
        switch phase {
        case .listening(let current) where current == sessionID:
            // An unsolicited stop must not silently start another microphone session.
            desiredListening = false
        case .stopping(let current) where current == sessionID:
            break
        default:
            return
        }
        guard finishingSessionID == nil else { return }
        phase = .stopping(sessionID)
        finishingSessionID = sessionID
        let currentEpoch = epoch
        onChange?()
        finishInjection(sessionID) { [weak self] in
            Self.onMain {
                guard let self, self.epoch == currentEpoch,
                      self.phase == .stopping(sessionID), self.finishingSessionID == sessionID
                else { return }
                self.finishingSessionID = nil
                self.retire(sessionID)
                self.phase = .ready
                self.reconcile()
                self.onChange?()
            }
        }
    }

    /// Opening the microphone failed before a session existed; retain a usable daemon.
    func microphoneOpenFailed(_ message: String) {
        precondition(Thread.isMainThread)
        guard phase == .starting else { return }
        invalidatePendingWork()
        phase = .ready
        onChange?()
        onFailure?(message)
    }

    /// A broken transport/daemon invalidates every pending request and injection task.
    func daemonFailed(_ message: String) {
        precondition(Thread.isMainThread)
        if case .failed = phase {
            // A daemon warm-up retry may have published Loading outside this session
            // state. Re-publish its failure without re-cancelling or repeating alerts.
            phase = .failed(message)
            onChange?()
            return
        }
        invalidatePendingWork()
        phase = .failed(message)
        onChange?()
        onFailure?(message)
    }

    func daemonReady() {
        precondition(Thread.isMainThread)
        invalidatePendingWork()
        phase = .ready
        onChange?()
    }

    func cancel() {
        precondition(Thread.isMainThread)
        invalidatePendingWork()
        phase = .ready
        onChange?()
    }

    private func invalidatePendingWork() {
        switch phase {
        case .listening(let sessionID), .stopping(let sessionID): retire(sessionID)
        default: break
        }
        epoch &+= 1
        desiredListening = false
        finishingSessionID = nil
        cancelInjection()
    }

    private func retire(_ sessionID: String) {
        guard !retiredSessionIDs.contains(sessionID) else { return }
        retiredSessionIDs.append(sessionID)
        if retiredSessionIDs.count > 64 { retiredSessionIDs.removeFirst() }
    }

    private func reconcile() {
        switch phase {
        case .ready where desiredListening:
            phase = .starting
            send(.start)
        case .listening(let sessionID) where !desiredListening:
            phase = .stopping(sessionID)
            send(.stop)
        default:
            break
        }
    }

    private func send(_ command: Command) {
        epoch &+= 1
        let commandEpoch = epoch
        sendCommand(command) { [weak self] result in
            Self.onMain {
                guard let self, self.epoch == commandEpoch else { return }
                if case .failure(let error) = result {
                    self.onCommandFailure?(error.localizedDescription)
                    self.daemonFailed(error.localizedDescription)
                }
                // Success only confirms a socket write. session_started/session_stopped
                // and the injection barrier are the authoritative transitions.
            }
        }
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
