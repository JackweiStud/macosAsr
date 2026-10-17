import Foundation

struct DictationUtterance: Equatable {
    let sessionID: String
    let utteranceID: Int
    let startedAt: TimeInterval
}

/// Prefix-diff injection, scoped to the sentence and listening session that produced it.
final class InjectionStateMachine {
    private let injector: TextInjecting
    private let injectionQueue = DispatchQueue(label: "com.macosasr.injection")
    private let queueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private var sessionID: String?
    private var generation: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    private var latestUtteranceID = 0
    private var discardedThroughID = 0
    private var lastUserInputAt: TimeInterval = 0

    // Only injectionQueue accesses pending text. Cancellation never waits for that queue.
    private var pendingText = ""
    private var pendingUtterance: DictationUtterance?

    var pendingLen: Int {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return pendingText.count
        }
        return injectionQueue.sync { pendingText.count }
    }

    init(injector: TextInjecting) {
        self.injector = injector
        injectionQueue.setSpecific(key: queueKey, value: ())
    }

    func onSessionStarted(_ sessionID: String, discardBefore: TimeInterval = 0) {
        stateLock.lock()
        generation &+= 1
        sessionGeneration &+= 1
        let epoch = generation
        self.sessionID = sessionID
        latestUtteranceID = 0
        discardedThroughID = 0
        lastUserInputAt = discardBefore
        stateLock.unlock()
        runOnInjectionQueue {
            self.stateLock.lock()
            let current = self.sessionID == sessionID && self.generation == epoch
            self.stateLock.unlock()
            guard current else { return }
            self.clearPending()
        }
    }

    func onPartial(_ text: String, utterance: DictationUtterance) {
        guard let token = captureToken(for: utterance) else { return }
        runOnInjectionQueue {
            self.applyPartial(text, utterance: utterance, token: token)
        }
    }

    func onFinal(_ text: String, utterance: DictationUtterance) {
        guard let token = captureToken(for: utterance) else { return }
        runOnInjectionQueue {
            guard self.applyText(text, utterance: utterance, token: token) else { return }
            self.clearPending()
            AppLogger.log("final u=\(utterance.utteranceID) len=\(text.count)")
        }
    }

    func onFiltered(utterance: DictationUtterance) {
        guard let token = captureToken(for: utterance) else { return }
        runOnInjectionQueue {
            guard self.isCurrent(utterance, token: token), self.pendingUtterance == utterance else { return }
            _ = self.injector.backspace(count: self.pendingText.count) {
                self.isCurrent(utterance, token: token)
            }
            self.clearPending()
        }
    }

    func onSessionStopped(_ stoppedSessionID: String? = nil, completion: (() -> Void)? = nil) {
        // Capture the session incarnation now: a reconnect can reuse the same daemon ID.
        // User clicks cancel writes without changing this session incarnation.
        stateLock.lock()
        let expectedSessionID = stoppedSessionID ?? sessionID
        let expectedSessionGeneration = sessionGeneration
        stateLock.unlock()
        // Preserve earlier final/flush tasks, including their cancellation by a user click.
        runOnInjectionQueue {
            // Always release the lifecycle barrier, even for an already-retired ID.
            defer { completion?() }
            self.stateLock.lock()
            guard let expectedSessionID, self.sessionID == expectedSessionID,
                  self.sessionGeneration == expectedSessionGeneration
            else {
                self.stateLock.unlock()
                return
            }
            self.generation &+= 1
            self.sessionID = nil
            self.stateLock.unlock()
            self.clearPending()
        }
    }

    @discardableResult
    func onUserInputInterrupted(at timestamp: TimeInterval = Date().timeIntervalSince1970) -> String? {
        stateLock.lock()
        guard let interruptedSessionID = sessionID else {
            stateLock.unlock()
            return nil
        }
        generation &+= 1
        discardedThroughID = max(discardedThroughID, latestUtteranceID)
        lastUserInputAt = max(lastUserInputAt, timestamp)
        let discardedID = discardedThroughID
        let cutoff = lastUserInputAt
        stateLock.unlock()
        runOnInjectionQueue {
            self.applyUserInputInterrupted(sessionID: interruptedSessionID, through: discardedID, before: cutoff)
        }
        return interruptedSessionID
    }

    private func runOnInjectionQueue(_ work: @escaping () -> Void) {
        injectionQueue.async(execute: work)
    }

    private func captureToken(for utterance: DictationUtterance) -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sessionID == utterance.sessionID,
              utterance.utteranceID > 0,
              utterance.startedAt.isFinite, utterance.startedAt > 0
        else { return nil }
        latestUtteranceID = max(latestUtteranceID, utterance.utteranceID)
        guard utterance.utteranceID > discardedThroughID, utterance.startedAt > lastUserInputAt else { return nil }
        return generation
    }

    private func isCurrent(_ utterance: DictationUtterance, token: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionID == utterance.sessionID && generation == token
            && utterance.utteranceID > discardedThroughID && utterance.startedAt > lastUserInputAt
    }

    private func applyPartial(_ text: String, utterance: DictationUtterance, token: UInt64) {
        _ = applyText(text, utterance: utterance, token: token)
    }

    @discardableResult
    private func applyText(_ text: String, utterance: DictationUtterance, token: UInt64) -> Bool {
        guard isCurrent(utterance, token: token) else { return false }
        if pendingUtterance != utterance { clearPending() }
        let (backspaceCount, suffix) = diff(old: pendingText, new: text)
        let shouldContinue = { self.isCurrent(utterance, token: token) }
        guard injector.backspace(count: backspaceCount, shouldContinue: shouldContinue),
              injector.typeText(suffix, shouldContinue: shouldContinue)
        else {
            clearPending()
            return false
        }
        pendingText = text
        pendingUtterance = utterance
        return true
    }

    private func applyUserInputInterrupted(sessionID: String, through utteranceID: Int, before cutoff: TimeInterval) {
        // A new sentence can enqueue between cancellation and this cleanup task.
        // Never clear that sentence's diff baseline or its final would repeat it.
        if let pendingUtterance, pendingUtterance.sessionID == sessionID,
           pendingUtterance.utteranceID <= utteranceID || pendingUtterance.startedAt <= cutoff
        {
            clearPending()
        }
        AppLogger.log("injection_pending_discarded_by_user_input")
    }

    private func clearPending() {
        pendingText = ""
        pendingUtterance = nil
    }

    private func diff(old: String, new: String) -> (Int, String) {
        let oldChars = Array(old)
        let newChars = Array(new)
        var commonLen = 0
        while commonLen < oldChars.count && commonLen < newChars.count
            && oldChars[commonLen] == newChars[commonLen]
        {
            commonLen += 1
        }
        return (oldChars.count - commonLen, String(newChars[commonLen...]))
    }
}
