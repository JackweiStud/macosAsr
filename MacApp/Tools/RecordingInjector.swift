import Foundation

/// A text field fake: every write obeys the same cancellation contract as TextInjector.
/// Tests never send CGEvents or read the real focused application.
final class RecordingInjector: TextInjecting {
    private let lock = NSLock()
    private var recordedOperations: [String] = []
    private var fieldText = ""
    private var mainThreadInjection = false
    private var gate: InjectionGate?

    var operations: [String] { locked { recordedOperations } }
    var text: String { locked { fieldText } }
    var sawMainThreadInjection: Bool { locked { mainThreadInjection } }

    func pauseNextWrite(afterCharacters count: Int = 1) -> InjectionGate {
        let newGate = InjectionGate(afterCharacters: count)
        locked { gate = newGate }
        return newGate
    }

    func send() {
        locked { fieldText = "" }
    }

    func backspace(count: Int, shouldContinue: () -> Bool) -> Bool {
        guard count > 0 else { return shouldContinue() }
        locked {
            if Thread.isMainThread { mainThreadInjection = true }
            recordedOperations.append("backspace:\(count)")
        }
        for _ in 0 ..< count {
            guard shouldContinue() else { return false }
            locked {
                if !fieldText.isEmpty { fieldText.removeLast() }
            }
            pauseIfNeeded()
        }
        return shouldContinue()
    }

    func typeText(_ text: String, shouldContinue: () -> Bool) -> Bool {
        guard !text.isEmpty else { return shouldContinue() }
        locked {
            if Thread.isMainThread { mainThreadInjection = true }
            recordedOperations.append("type:\(text)")
        }
        for character in text {
            guard shouldContinue() else { return false }
            locked { fieldText.append(character) }
            pauseIfNeeded()
        }
        return shouldContinue()
    }

    private func pauseIfNeeded() {
        let currentGate = locked { gate }
        if currentGate?.didWriteCharacter() == true {
            locked { gate = nil }
            currentGate?.pause()
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}

final class InjectionGate {
    private var remainingCharacters: Int
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    init(afterCharacters: Int) { remainingCharacters = afterCharacters }

    // Called only from the serial injection queue.
    func didWriteCharacter() -> Bool {
        remainingCharacters -= 1
        return remainingCharacters == 0
    }

    func pause() {
        reached.signal()
        resume.wait()
    }

    func waitUntilPaused() -> Bool {
        reached.wait(timeout: .now() + 3) == .success
    }

    func release() { resume.signal() }
}

