import Foundation

private final class LifecycleFixture {
    let injector = RecordingInjector()
    lazy var injection = InjectionStateMachine(injector: injector)
    var commands: [SessionLifecycle.Command] = []
    var replies: [(Result<Void, Error>) -> Void] = []
    var failures: [String] = []
    var callbackOffMain = false
    lazy var lifecycle: SessionLifecycle = {
        let value = SessionLifecycle(
            sendCommand: { [unowned self] command, completion in
                commands.append(command)
                replies.append(completion)
            },
            beginInjection: { [unowned self] sessionID, cutoff in injection.onSessionStarted(sessionID, discardBefore: cutoff ?? 0) },
            finishInjection: { [unowned self] sessionID, completion in
                injection.onSessionStopped(sessionID, completion: completion)
            },
            cancelInjection: { [unowned self] in
                if let sessionID = injection.onUserInputInterrupted() { injection.onSessionStopped(sessionID) }
            })
        value.onChange = { [unowned self] in callbackOffMain = callbackOffMain || !Thread.isMainThread }
        value.onFailure = { [unowned self] message in failures.append(message) }
        return value
    }()
    func start(_ id: String = "a", socketReplyFirst: Bool = true) {
        lifecycle.setDesiredListening(true)
        if socketReplyFirst { replies.last?(.success(())) }
        check(lifecycle.phase == .starting, "socket success falsely confirmed listening")
        check(lifecycle.sessionStarted(id), "start acknowledgement was rejected")
        if !socketReplyFirst { replies.last?(.success(())) }
        _ = injection.pendingLen
    }
    func utterance(_ id: Int = 1, session: String = "a") -> DictationUtterance {
        DictationUtterance(sessionID: session, utteranceID: id, startedAt: 10)
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private func pump(until predicate: () -> Bool, _ message: String) {
    let deadline = Date().addingTimeInterval(3)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    check(predicate(), message)
}
private func failure(_ message: String = "socket failed") -> Result<Void, Error> {
    .failure(NSError(domain: "LifecycleSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
}

@main
struct SessionLifecycleSelfTest {
    static func main() {
        testQuickStopStart(socketReplyFirst: true)
        testQuickStopStart(socketReplyFirst: false)
        testRestartWaitsForRealInjectionBarrier()
        testStartingStopAndMultipleToggles()
        testStartingStopThenResume()
        testMicrophoneFailureAllowsRetry()
        testSendFailureClearsIntent()
        testDaemonExitDuringDrainCannotRestart()
        testClickAfterStopStillCancelsInjection()
        testBackgroundSendCallbackReturnsToMain()
        testRecoveryBeforeOldCancelledInjectionDrains()
        testResumedSessionDiscardsPreReconnectResults()
        testStaleCommandFailureCannotInvokeTransportCleanup()
        print("PASS: production session lifecycle regression self-test (13 cases)")
    }

    private static func testQuickStopStart(socketReplyFirst: Bool) {
        let f = LifecycleFixture()
        f.start(socketReplyFirst: socketReplyFirst)
        f.lifecycle.setDesiredListening(false)
        f.lifecycle.setDesiredListening(true)
        check(f.lifecycle.phase == .stopping("a") && f.lifecycle.desiredListening, "restart intent was lost")
        check(f.commands == [.start, .stop], "restart was sent before old stopped ack")
        if socketReplyFirst { f.replies[1](.success(())) }
        f.lifecycle.sessionStopped("a")
        if !socketReplyFirst { f.replies[1](.success(())) }
        pump(until: { f.commands.count == 3 }, "stopped session did not release queued restart")
        check(f.lifecycle.phase == .starting, "restart was falsely marked listening")
        if socketReplyFirst { f.replies[2](.success(())) }
        check(f.lifecycle.sessionStarted("b"), "new session was not accepted")
        if !socketReplyFirst { f.replies[2](.success(())) }
        f.lifecycle.sessionStopped("a")
        check(!f.lifecycle.sessionStarted("a"), "retired session restarted injection")
        check(f.lifecycle.phase == .listening("b"), "old stopped event disabled session B")
        check(f.commands == [.start, .stop, .start], "duplicate events issued extra commands")
    }

    private static func testRestartWaitsForRealInjectionBarrier() {
        let f = LifecycleFixture(); f.start()
        let gate = f.injector.pauseNextWrite()
        f.injection.onFinal("tail must finish", utterance: f.utterance())
        check(gate.waitUntilPaused(), "tail injection did not pause")
        f.lifecycle.setDesiredListening(false)
        f.lifecycle.setDesiredListening(true)
        f.lifecycle.sessionStopped("a")
        check(f.commands == [.start, .stop], "new start cancelled old tail before barrier")
        check(f.lifecycle.phase == .stopping("a"), "UI left finishing before keyboard writes completed")
        gate.release()
        pump(until: { f.commands.count == 3 }, "real injection barrier failed to restart")
        check(f.injector.text == "tail must finish", "normal quick restart truncated old final")
        check(f.lifecycle.sessionStarted("b"), "B did not start after barrier")
        f.injection.onFinal("B", utterance: f.utterance(session: "b"))
        _ = f.injection.pendingLen
        check(f.injector.text == "tail must finishB", "new session failed after draining old tail")
    }

    private static func testStartingStopAndMultipleToggles() {
        let f = LifecycleFixture()
        f.lifecycle.setDesiredListening(true)
        f.lifecycle.setDesiredListening(false)
        check(f.commands == [.start], "stop before started sent an unscoped command")
        check(f.lifecycle.sessionStarted("a"), "cancelled startup ack was rejected")
        check(f.commands == [.start, .stop], "starting stop was not applied after ack")
        for desired in [true, false, true, false] { f.lifecycle.setDesiredListening(desired) }
        f.lifecycle.sessionStopped("a")
        pump(until: { f.lifecycle.phase == .ready }, "multiple toggles did not settle ready")
        check(f.commands == [.start, .stop] && !f.lifecycle.desiredListening, "toggles did not honor final stop intent")
    }

    private static func testStartingStopThenResume() {
        let f = LifecycleFixture()
        for desired in [true, false, true] { f.lifecycle.setDesiredListening(desired) }
        check(f.lifecycle.sessionStarted("a"), "resumed start rejected")
        check(f.commands == [.start] && f.lifecycle.phase == .listening("a"), "starting toggles sent redundant stop/start")
    }

    private static func testMicrophoneFailureAllowsRetry() {
        let f = LifecycleFixture()
        f.lifecycle.setDesiredListening(true)
        let oldReply = f.replies[0]
        f.lifecycle.microphoneOpenFailed("mic_open_failed")
        check(f.lifecycle.phase == .ready && !f.lifecycle.desiredListening, "mic failure did not restore ready")
        check(f.failures == ["mic_open_failed"], "mic failure was not reported")
        f.lifecycle.setDesiredListening(true)
        f.lifecycle.sessionStopped("a") // Old stopped must not clear the new failure callback/intent.
        oldReply(failure("old write failed"))
        check(f.lifecycle.phase == .starting && f.failures.count == 1, "old callback overwrote retry")
        f.lifecycle.microphoneOpenFailed("retry failed")
        check(f.failures == ["mic_open_failed", "retry failed"], "retry failure feedback was lost")
        f.start("b")
        check(f.lifecycle.phase == .listening("b"), "microphone retry did not recover")
    }

    private static func testSendFailureClearsIntent() {
        let f = LifecycleFixture()
        f.lifecycle.setDesiredListening(true)
        f.replies[0](failure())
        check(f.lifecycle.phase == .failed("socket failed") && !f.lifecycle.desiredListening, "start write failure retained intent")
        f.lifecycle.daemonReady(); f.start("b")
        f.lifecycle.setDesiredListening(false)
        f.lifecycle.setDesiredListening(true)
        f.replies.last?(failure("stop failed"))
        f.lifecycle.sessionStopped("b")
        check(f.lifecycle.phase == .failed("stop failed") && !f.lifecycle.desiredListening, "stop failure retained restart")
        check(f.commands.count == 3 && f.failures == ["socket failed", "stop failed"], "send failures issued retry commands or lost feedback")
    }

    private static func testDaemonExitDuringDrainCannotRestart() {
        let f = LifecycleFixture(); f.start()
        let gate = f.injector.pauseNextWrite()
        f.injection.onFinal("unfinished", utterance: f.utterance())
        check(gate.waitUntilPaused(), "daemon-exit tail did not pause")
        f.lifecycle.setDesiredListening(false); f.lifecycle.setDesiredListening(true)
        f.lifecycle.sessionStopped("a")
        f.lifecycle.daemonFailed("daemon exited")
        gate.release()
        _ = f.injection.pendingLen
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        check(f.lifecycle.phase == .failed("daemon exited") && !f.lifecycle.desiredListening, "stale drain resurrected failed daemon")
        check(f.commands == [.start, .stop], "daemon failure sent queued restart")
        check(f.injector.text == "u", "daemon failure failed to cancel unfinished injection")
        f.lifecycle.daemonReady(); f.start("b")
        check(!f.lifecycle.sessionStarted("a") && f.lifecycle.phase == .listening("b"), "old session survived daemon recovery")
    }

    private static func testClickAfterStopStillCancelsInjection() {
        let f = LifecycleFixture(); f.start()
        let gate = f.injector.pauseNextWrite()
        f.injection.onFinal("unfinished", utterance: f.utterance())
        check(gate.waitUntilPaused(), "click tail did not pause")
        f.lifecycle.setDesiredListening(false); f.lifecycle.setDesiredListening(true)
        f.lifecycle.sessionStopped("a")
        f.injector.send()
        check(f.injection.onUserInputInterrupted(at: 100) == "a", "stop barrier hid cancellable old session")
        gate.release()
        pump(until: { f.commands.count == 3 }, "cancelled tail did not release restart")
        check(f.injector.text.isEmpty, "click after stop refilled unfinished final")
    }

    private static func testRecoveryBeforeOldCancelledInjectionDrains() {
        let f = LifecycleFixture(); f.start()
        let gate = f.injector.pauseNextWrite()
        f.injection.onFinal("unfinished", utterance: f.utterance())
        check(gate.waitUntilPaused(), "recovery tail did not pause")
        f.lifecycle.daemonFailed("connection lost")
        f.lifecycle.daemonReady()
        f.lifecycle.setDesiredListening(true)
        check(f.lifecycle.sessionStarted("b"), "B was not accepted during old queue cancellation")
        f.injection.onFinal("B", utterance: f.utterance(session: "b"))
        gate.release()
        _ = f.injection.pendingLen
        check(f.injector.text == "uB", "queued old-session cleanup cancelled new B injection")
    }

    private static func testResumedSessionDiscardsPreReconnectResults() {
        let f = LifecycleFixture(); f.start()
        f.lifecycle.daemonFailed("connection lost")
        f.lifecycle.daemonReady()
        f.lifecycle.setDesiredListening(true)
        check(f.lifecycle.sessionStarted("a", resumedAt: 100), "explicit current-connection resume was rejected")
        f.injection.onFinal("old speech", utterance: f.utterance())
        _ = f.injection.pendingLen
        check(f.injector.text.isEmpty, "reconnect filled pre-reconnect speech")
        f.injection.onFinal("fresh", utterance: DictationUtterance(sessionID: "a", utteranceID: 2, startedAt: 100.1))
        _ = f.injection.pendingLen
        check(f.injector.text == "fresh", "resume discarded post-reconnect speech")
    }

    private static func testStaleCommandFailureCannotInvokeTransportCleanup() {
        let f = LifecycleFixture()
        var cleanups = 0
        f.lifecycle.onCommandFailure = { _ in cleanups += 1 }
        f.start()
        let oldStartReply = f.replies[0]
        f.lifecycle.setDesiredListening(false); f.lifecycle.setDesiredListening(true)
        f.lifecycle.sessionStopped("a")
        pump(until: { f.commands.count == 3 }, "stale-callback fixture did not restart")
        check(f.lifecycle.sessionStarted("b"), "stale-callback B did not start")
        oldStartReply(failure("late A write failure"))
        check(cleanups == 0 && f.lifecycle.phase == .listening("b"), "stale command bypassed epoch via transport cleanup")
        f.replies[2](failure("current B write failure"))
        check(cleanups == 1 && f.lifecycle.phase == .failed("current B write failure"), "current command failure did not clean transport")
    }

    private static func testBackgroundSendCallbackReturnsToMain() {
        let f = LifecycleFixture()
        f.lifecycle.setDesiredListening(true)
        let reply = f.replies[0]
        DispatchQueue.global().async { reply(failure("background send failed")) }
        pump(until: { !f.failures.isEmpty }, "background send failure was lost")
        check(!f.callbackOffMain && f.lifecycle.phase == .failed("background send failed"), "send callback mutated lifecycle off main")
    }
}
