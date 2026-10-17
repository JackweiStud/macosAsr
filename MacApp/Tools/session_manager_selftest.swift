import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
private func pump(until predicate: () -> Bool, _ message: String) {
    let deadline = Date().addingTimeInterval(4)
    while !predicate() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    check(predicate(), message)
}
private func failed(_ message: String) -> Error {
    NSError(domain: "ManagerSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private final class ManagerFixture {
    let manager = DaemonManager.shared
    let injector = RecordingInjector()
    let injection: InjectionStateMachine
    let controller: LiveDictationController
    let client: DaemonClient
    var observedStates: [DaemonState] = []
    var stateCallbackOffMain = false
    var failures: [String] = []

    init() {
        injection = InjectionStateMachine(injector: injector)
        controller = LiveDictationController(stateMachine: injection)
        client = DaemonClient.latest!
        manager.onStateChange = { [unowned self] state in
            self.observedStates.append(state)
            self.stateCallbackOffMain = self.stateCallbackOffMain || !Thread.isMainThread
        }
    }
    func prepareSocket() {
        check(FileManager.default.createFile(atPath: ProjectPaths.socketPath.path, contents: Data()), "could not create isolated dummy socket")
    }
    func warmUp() {
        prepareSocket()
        let previous = client.pingReplies.count
        manager.warmUp()
        pump(until: { self.client.pingReplies.count == previous + 1 }, "Manager did not connect and ping isolated transport")
        check(manager.state == .loading, "warmup falsely became ready before pong")
        client.pingReplies.last?(.success(DaemonEvent(type: "pong", raw: ["model_loaded": true, "calibrated": true])))
        pump(until: { self.manager.state == .ready }, "ready pong did not update Manager")
        check(client.commands("config_update").count >= 1, "Manager did not push runtime settings after ready")
        check(client.connectCount >= 1 && client.connected, "warmup bypassed controllable transport")
        check(!controller.isActive, "Controller active before a started acknowledgement")
    }
    func requestStart() {
        controller.start { [unowned self] message in self.failures.append(message) }
    }
    func acknowledgeStart(_ id: String, resumed: Bool = false) {
        client.emit("session_started", raw: ["session_id": id, "resumed": resumed])
        check(manager.state == .listening && controller.isActive, "Manager/Controller disagreed after started(\(id))")
    }
    func start(_ id: String) {
        requestStart()
        check(manager.state == .starting && !controller.isActive, "request itself confirmed listening")
        client.commands("session_start").last?.completion?(.success(()))
        check(manager.state == .starting && !controller.isActive, "socket write success confirmed listening")
        acknowledgeStart(id)
        _ = injection.pendingLen
    }
    func text(_ type: String, _ value: String, session: String, id: Int = 1, at: TimeInterval = 10) {
        client.emit(type, raw: ["session_id": session, "utterance_id": id, "utterance_started_at": at, "text": value])
    }
    func checkThreading() {
        check(!stateCallbackOffMain, "Manager state callback escaped main thread")
        check(!injector.sawMainThreadInjection, "Controller injected text on main thread")
    }
}

@main
struct SessionManagerSelfTest {
    static func main() {
        check(Thread.isMainThread, "self-test must start on main thread")
        guard CommandLine.arguments.count == 2 else { fatalError("scenario argument required") }
        switch CommandLine.arguments[1] {
        case "acknowledgement": testAcknowledgement()
        case "quick-restart": testQuickRestart()
        case "resumed-session": testResumedSession()
        case "microphone-retry": testMicrophoneRetry()
        case "stale-completions": testStaleCompletions()
        case "stop-while-starting": testStopWhileStarting()
        case "repeated-warmup-failure": testRepeatedWarmUpFailure()
        default: fatalError("unknown scenario")
        }
        print("PASS: production Manager/Controller integration — \(CommandLine.arguments[1])")
    }

    private static func testAcknowledgement() {
        let f = ManagerFixture(); f.warmUp(); f.start("A")
        check(f.client.commands("session_start").last?.extra["language"] as? String == "Chinese", "Manager omitted start language")
        f.text("partial", "收到确认", session: "A")
        _ = f.injection.pendingLen
        check(f.injector.text == "收到确认", "Controller did not forward real partial to injection")
        f.controller.stop()
        check(f.manager.state == .stopping && !f.controller.isActive, "stop failed to show finishing state")
        f.client.commands("session_stop").last?.completion?(.success(()))
        check(f.manager.state == .stopping, "stop socket write cleared state before acknowledgement")
        f.client.emit("session_stopped", raw: ["session_id": "A"])
        pump(until: { f.manager.state == .ready }, "stop acknowledgement plus injection barrier did not settle ready")
        check(!f.manager.desiredListening && !f.controller.isActive, "stopped Manager retained active UI/intent")
        f.checkThreading()
    }

    private static func testQuickRestart() {
        let f = ManagerFixture(); f.warmUp(); f.start("A")
        let gate = f.injector.pauseNextWrite()
        f.text("final", "旧会话尾音完整保留", session: "A")
        check(gate.waitUntilPaused(), "final text did not reach actual injection queue")
        f.controller.stop(); f.requestStart()
        check(f.manager.state == .stopping && f.manager.desiredListening && !f.controller.isActive, "restart intent or finishing UI lost")
        check(f.client.commands("session_start").count == 1 && f.client.commands("session_stop").count == 1, "Manager started B before stopped(A)")
        f.client.commands("session_stop").last?.completion?(.success(()))
        f.client.emit("session_stopped", raw: ["session_id": "A"])
        check(f.manager.state == .stopping && f.client.commands("session_start").count == 1, "new start crossed pending injection barrier")
        gate.release()
        pump(until: { f.client.commands("session_start").count == 2 }, "real injection barrier did not release queued start")
        check(f.injector.text == "旧会话尾音完整保留", "normal quick restart truncated previous final")
        check(f.manager.state == .starting && !f.controller.isActive, "B became active before daemon acknowledgement")
        f.client.commands("session_start").last?.completion?(.success(()))
        f.acknowledgeStart("B")
        f.client.emit("session_stopped", raw: ["session_id": "A"])
        f.client.emit("session_started", raw: ["session_id": "A"])
        check(f.manager.state == .listening && f.controller.isActive && f.manager.desiredListening, "duplicate A event disabled/replaced B")
        f.text("final", "新会话", session: "B")
        _ = f.injection.pendingLen
        check(f.injector.text == "旧会话尾音完整保留新会话", "Controller did not inject B after retiring A")
        f.checkThreading()
    }

    private static func testResumedSession() {
        let f = ManagerFixture(); f.warmUp(); f.requestStart(); f.acknowledgeStart("background-A", resumed: true)
        let discarded = f.client.commands("discard_utterance")
        check(discarded.count == 1, "resumed background session did not discard old daemon audio")
        check(discarded[0].extra["session_id"] as? String == "background-A", "resume discard targeted wrong session")
        guard let cutoff = discarded[0].extra["before"] as? TimeInterval else { fatalError("resume discard omitted cutoff") }
        f.text("partial", "重连前旧音频不能回填", session: "background-A", at: cutoff - 1)
        f.text("final", "重连前完整旧句不能回填", session: "background-A", at: cutoff - 1)
        _ = f.injection.pendingLen
        check(f.injector.text.isEmpty, "resumed session allowed old audio to inject")
        f.text("partial", "重连后新句", session: "background-A", id: 2, at: cutoff + 1)
        f.text("final", "重连后新句。", session: "background-A", id: 2, at: cutoff + 1)
        _ = f.injection.pendingLen
        check(f.injector.text == "重连后新句。", "resume cancellation gate blocked fresh speech or duplicated text")
        f.checkThreading()
    }

    private static func testMicrophoneRetry() {
        let f = ManagerFixture(); f.warmUp(); f.requestStart()
        let staleStart = f.client.commands("session_start")[0].completion!
        f.client.emit("error", raw: ["code": "mic_open_failed", "message": "mic denied"])
        check(f.manager.state == .ready && !f.manager.desiredListening && f.failures == ["mic denied"], "microphone failure did not leave reusable daemon")
        f.requestStart()
        let disconnects = f.client.disconnectCount
        staleStart(.failure(failed("obsolete start failure")))
        check(f.manager.state == .starting && f.client.disconnectCount == disconnects, "obsolete start failure cleaned new retry transport")
        f.acknowledgeStart("retry-B")
        f.text("final", "重试成功", session: "retry-B")
        _ = f.injection.pendingLen
        check(f.injector.text == "重试成功" && f.failures == ["mic denied"], "retry failure callback or text state was contaminated")
        f.checkThreading()
    }

    private static func testStaleCompletions() {
        let f = ManagerFixture(); f.warmUp(); f.start("A")
        let staleSend = f.client.commands("session_start")[0].completion!
        let stalePing = f.client.pingReplies[0]
        f.client.onConnectionFailure?(failed("active transport closed"))
        if case .error = f.manager.state {} else { fatalError("active transport failure was not surfaced") }
        check(!f.controller.isActive && !f.manager.desiredListening, "transport failure retained listening UI")
        f.warmUp(); f.start("B")
        let disconnects = f.client.disconnectCount
        staleSend(.failure(failed("old connection send failed late")))
        stalePing(.failure(failed("old warmup ping failed late")))
        f.client.emit("session_stopped", raw: ["session_id": "A"])
        check(f.client.disconnectCount == disconnects && f.client.connected, "stale completion disconnected recovered transport")
        check(f.manager.state == .listening && f.controller.isActive && f.manager.desiredListening, "stale callback overwrote recovered B state")
        f.text("final", "恢复后的输入", session: "B")
        _ = f.injection.pendingLen
        check(f.injector.text == "恢复后的输入", "recovered Controller injection was cancelled by old work")
        f.checkThreading()
    }

    private static func testRepeatedWarmUpFailure() {
        let f = ManagerFixture()
        // The isolated fake path is absent, so locateRepoRoot deterministically
        // rejects spawn without touching a real socket or launching a process.
        try? FileManager.default.removeItem(at: ProjectPaths.socketPath)
        var cancellationCount = 0
        var failureCount = 0
        let originalCancel = f.manager.cancelInjection
        let originalFailure = f.manager.onSessionFailure
        f.manager.cancelInjection = { cancellationCount += 1; originalCancel?() }
        f.manager.onSessionFailure = { message in failureCount += 1; originalFailure?(message) }
        f.manager.warmUp()
        pump(until: { if case .error = f.manager.state { return true }; return false }, "first failed warmup did not show error")
        let firstStateCount = f.observedStates.count
        check(cancellationCount == 1 && failureCount == 1, "first failure did not cancel/report exactly once")
        f.manager.warmUp() // Honor the real two-second retry backoff.
        pump(until: {
            guard f.observedStates.count > firstStateCount else { return false }
            if case .error = f.manager.state { return true }
            return false
        }, "second failed warmup left UI stuck loading")
        check(f.observedStates.filter { if case .error = $0 { return true }; return false }.count == 2,
              "each failed warmup must publish an error state")
        check(cancellationCount == 1 && failureCount == 1, "already-failed state repeated cancellation/failure alert")
        f.warmUp() // A subsequent healthy connection remains retryable.
        f.start("recovered")
        check(f.manager.state == .listening && f.controller.isActive, "repeated warmup failures prevented recovery")
        f.checkThreading()
    }

    private static func testStopWhileStarting() {
        let f = ManagerFixture(); f.warmUp(); f.requestStart(); f.controller.stop()
        check(f.manager.state == .starting && !f.manager.desiredListening && f.client.commands("session_stop").isEmpty, "stop during start sent unscoped stop")
        f.client.emit("session_started", raw: ["session_id": "A"])
        check(f.manager.state == .stopping && !f.controller.isActive && f.client.commands("session_stop").count == 1, "late start acknowledgement did not honor stop intent")
        f.client.emit("session_stopped", raw: ["session_id": "A"])
        pump(until: { f.manager.state == .ready }, "stop during startup did not settle ready")
        check(f.client.commands("session_start").count == 1, "stop during startup caused unintended restart")
        f.checkThreading()
    }
}
