import Foundation

private final class LockedValue<T> {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@main
struct InjectionQueueSelfTest {
    static func main() {
        testBackgroundInjectionOrdering()
        testSendRejectsLateResultsAndKeepsNextUtterance()
        testTimestampRejectsFinalBeforeAnyPartial()
        testRepeatedClicksOnlyDiscardUtterancesBeforeLatestClick()
        testNormalStopPreservesAlreadyQueuedFinal()
        testClickAfterStopCancelsUnfinishedFinal()
        testPreviousSessionCannotChangeCurrentSession()
        testClickCancelsInFlightCharactersAndQueuedWork()
        testMismatchedStopAlwaysCompletesBarrier()
        print("PASS: injection queue ordering and send-residual regression self-test (9 cases)")
    }

    private static func utterance(_ id: Int, at startedAt: TimeInterval = 10,
                                  session: String = "session-a") -> DictationUtterance {
        DictationUtterance(sessionID: session, utteranceID: id, startedAt: startedAt)
    }

    private static func fixture(_ session: String = "session-a") -> (RecordingInjector, InjectionStateMachine) {
        let injector = RecordingInjector()
        let state = InjectionStateMachine(injector: injector)
        state.onSessionStarted(session)
        _ = state.pendingLen
        return (injector, state)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func testBackgroundInjectionOrdering() {
        let (injector, state) = fixture()
        let current = utterance(1)
        state.onPartial("hello", utterance: current)
        state.onPartial("hello world", utterance: current)
        state.onFinal("hello there", utterance: current)

        check(state.pendingLen == 0, "pending text was not cleared after final")
        check(injector.operations == ["type:hello", "type: world", "backspace:5", "type:there"],
              "unexpected ordered diff operations: \(injector.operations)")
        check(injector.text == "hello there", "ordered injection produced wrong text")
        check(!injector.sawMainThreadInjection, "injection ran on main thread")
    }

    private static func testSendRejectsLateResultsAndKeepsNextUtterance() {
        let (injector, state) = fixture()
        let old = utterance(1, at: 90)
        state.onPartial("already sent", utterance: old)
        check(state.pendingLen == 12, "old partial was not injected")
        injector.send()
        check(state.onUserInputInterrupted(at: 100) == "session-a", "interrupt did not identify session")
        check(state.pendingLen == 0, "interrupt did not clear pending state")
        let before = injector.operations
        state.onPartial("already sent again", utterance: old)
        state.onFinal("already sent final", utterance: old)
        state.onFiltered(utterance: old)
        check(state.pendingLen == 0, "late results restored pending state")
        check(injector.text.isEmpty, "sent utterance was reinserted")
        check(injector.operations == before, "late results typed or backspaced after send")

        // Speech starts only 100 ms after the click. It must not be swallowed by pre-roll.
        let next = utterance(2, at: 100.1)
        state.onPartial("next sentence", utterance: next)
        check(state.pendingLen == 13, "next utterance was suppressed after send")
        let nextOperations = injector.operations
        state.onFiltered(utterance: old)
        state.onPartial("stale partial", utterance: old)
        state.onFinal("stale final", utterance: old)
        check(state.pendingLen == 13, "old results changed next utterance state")
        check(injector.operations == nextOperations, "old results modified next utterance text")
        state.onFinal("next sentence", utterance: next)
        check(state.pendingLen == 0 && injector.text == "next sentence", "next sentence did not finish normally")
    }

    private static func testTimestampRejectsFinalBeforeAnyPartial() {
        let (injector, state) = fixture()
        state.onUserInputInterrupted(at: 100)
        state.onFinal("late final without partial", utterance: utterance(1, at: 99))
        state.onFiltered(utterance: utterance(1, at: 99))
        check(state.pendingLen == 0 && injector.text.isEmpty, "timestamp did not reject unseen old final")
        check(injector.operations.isEmpty, "unseen old final caused keyboard operations")
        state.onFinal("new speech", utterance: utterance(2, at: 100.1))
        check(state.pendingLen == 0 && injector.text == "new speech", "new final without partial was suppressed")
    }

    private static func testRepeatedClicksOnlyDiscardUtterancesBeforeLatestClick() {
        let (injector, state) = fixture()
        state.onPartial("first", utterance: utterance(1, at: 90))
        _ = state.pendingLen
        injector.send()
        state.onUserInputInterrupted(at: 100)
        state.onUserInputInterrupted(at: 101)
        state.onFinal("between clicks", utterance: utterance(2, at: 100.1))
        check(state.pendingLen == 0 && injector.text.isEmpty, "second click did not invalidate intervening speech")
        state.onPartial("after clicks", utterance: utterance(3, at: 101.1))
        state.onFinal("after clicks", utterance: utterance(3, at: 101.1))
        check(state.pendingLen == 0 && injector.text == "after clicks", "repeated clicks stopped whole dictation session")
    }

    private static func testNormalStopPreservesAlreadyQueuedFinal() {
        let (injector, state) = fixture()
        let gate = injector.pauseNextWrite()
        let current = utterance(1)
        state.onPartial("hello", utterance: current)
        check(gate.waitUntilPaused(), "normal-stop test did not reach paused injection")
        state.onFinal("hello world", utterance: current)
        state.onSessionStopped("session-a")
        gate.release()
        check(state.pendingLen == 0 && injector.text == "hello world", "normal stop cancelled an already queued final")
    }

    private static func testClickAfterStopCancelsUnfinishedFinal() {
        let (injector, state) = fixture()
        let gate = injector.pauseNextWrite()
        let current = utterance(1)
        state.onFinal("unfinished final", utterance: current)
        check(gate.waitUntilPaused(), "stop-click test did not reach paused final")
        state.onSessionStopped("session-a")
        injector.send()
        interruptWithoutWaitingForInjection(state, gate: gate, at: 100)
        check(state.pendingLen == 0 && injector.text.isEmpty, "click after stop restored unfinished final")
    }

    private static func testPreviousSessionCannotChangeCurrentSession() {
        let (injector, state) = fixture()
        let old = utterance(1)
        state.onPartial("previous session", utterance: old)
        _ = state.pendingLen
        injector.send()
        state.onSessionStopped("session-a")
        state.onSessionStarted("session-b")
        let next = utterance(1, at: 200, session: "session-b")
        state.onPartial("current session", utterance: next)
        check(state.pendingLen == 15, "new session partial was not injected")
        let before = injector.operations
        state.onPartial("stale previous partial", utterance: old)
        state.onFinal("stale previous final", utterance: old)
        state.onFiltered(utterance: old)
        state.onSessionStopped("session-a")
        check(state.pendingLen == 15, "previous session changed current pending state")
        check(injector.operations == before, "previous session wrote to current field")
        state.onFinal("current session", utterance: next)
        check(state.pendingLen == 0 && injector.text == "current session", "new session could not finish")
    }

    private static func testClickCancelsInFlightCharactersAndQueuedWork() {
        let (injector, state) = fixture()
        let gate = injector.pauseNextWrite()
        let old = utterance(1, at: 90)
        state.onPartial("abcdefghijk", utterance: old)
        check(gate.waitUntilPaused(), "in-flight test did not reach paused partial")
        state.onPartial("queued old partial", utterance: old)
        state.onFinal("queued old final", utterance: old)
        state.onFiltered(utterance: old)
        injector.send()
        interruptWithoutWaitingForInjection(state, gate: gate, at: 100)
        check(state.pendingLen == 0 && injector.text.isEmpty, "in-flight or queued text survived send cancellation")
        check(injector.operations == ["type:abcdefghijk"], "queued stale work reached injector")
        let next = utterance(2, at: 100.1)
        state.onPartial("fresh text", utterance: next)
        state.onFinal("fresh text", utterance: next)
        check(state.pendingLen == 0 && injector.text == "fresh text", "cancellation prevented subsequent dictation")
    }

    private static func testMismatchedStopAlwaysCompletesBarrier() {
        let (injector, state) = fixture()
        state.onPartial("current", utterance: utterance(1))
        let completed = DispatchSemaphore(value: 0)
        state.onSessionStopped("old-session") { completed.signal() }
        check(completed.wait(timeout: .now() + 3) == .success, "mismatched stop never released barrier")
        check(state.pendingLen == 7 && injector.text == "current", "mismatched stop cleared current session")
    }

    private static func interruptWithoutWaitingForInjection(_ state: InjectionStateMachine,
                                                            gate: InjectionGate, at: TimeInterval) {
        let interrupted = DispatchSemaphore(value: 0)
        let session = LockedValue<String?>(nil)
        DispatchQueue.global().async {
            session.set(state.onUserInputInterrupted(at: at))
            interrupted.signal()
        }
        let completedWhilePaused = interrupted.wait(timeout: .now() + 3) == .success
        gate.release()
        check(completedWhilePaused, "user interruption waited for blocked keyboard injection")
        check(session.get() == "session-a", "interruption did not return the affected session")
    }
}
