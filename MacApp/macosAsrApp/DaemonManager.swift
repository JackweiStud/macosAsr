import Darwin
import Foundation

/// 守护进程状态（单一事实源，驱动菜单栏 UI）
enum DaemonState: Equatable {
    case idle           // 尚未启动
    case loading        // 已 spawn / 正在加载模型 / 校准中
    case ready          // 已就绪，可开始听写
    case starting       // 已请求开始，等待 session_started
    case listening      // 听写中（session_started）
    case stopping       // 等待 daemon 收尾及旧文本注入完成
    case error(String)  // 启动/连接失败
}

/// 启动并管理 asr_daemon 生命周期。App 启动即 warmUp，菜单栏据此显示状态。
final class DaemonManager {
    static let shared = DaemonManager()

    private var daemonProcess: Process?
    private let client = DaemonClient()
    private var clientConnected = false
    private var warming = false
    private var isShuttingDown = false
    private var consecutiveRestartFailures = 0
    private let maxRestartFailures = 3
    private let restartBackoffSeconds: TimeInterval = 2.0
    private var lastRestartFailureAt = Date.distantPast
    private var pendingWarmUpAfterBackoff = false
    private var warmUpEpoch: UInt64 = 0
    var onInjectionSessionStarted: ((String, TimeInterval?) -> Void)?
    var finishInjectionSession: ((String, @escaping () -> Void) -> Void)?
    var cancelInjection: (() -> Void)?
    var onSessionFailure: ((String) -> Void)?
    var eventHandler: ((DaemonEvent) -> Void)?

    private lazy var sessionLifecycle: SessionLifecycle = {
        let lifecycle = SessionLifecycle(
            sendCommand: { [weak self] command, completion in
                guard let self else { return }
                let extra: [String: Any] = command == .start ? ["language": ConfigManager.shared.language] : [:]
                self.client.send(cmd: command.rawValue, extra: extra, completion: completion)
            },
            beginInjection: { [weak self] sessionID, resumedAt in self?.onInjectionSessionStarted?(sessionID, resumedAt) },
            finishInjection: { [weak self] sessionID, completion in
                if let finish = self?.finishInjectionSession { finish(sessionID, completion) }
                else { completion() }
            },
            cancelInjection: { [weak self] in self?.cancelInjection?() }
        )
        lifecycle.onChange = { [weak self] in self?.applySessionPhase() }
        lifecycle.onCommandFailure = { [weak self] message in self?.markDaemonFailed(message) }
        lifecycle.onFailure = { [weak self] message in self?.onSessionFailure?(message) }
        return lifecycle
    }()

    var desiredListening: Bool { sessionLifecycle.desiredListening }

    private(set) var state: DaemonState = .idle {
        didSet {
            if oldValue != state {
                AppLogger.log("daemon_state \(oldValue) -> \(state)")
                onStateChange?(state)
            }
        }
    }

    /// 状态变化回调，主线程触发
    var onStateChange: ((DaemonState) -> Void)?

    private init() {
        client.onEvent = { [weak self] event in
            guard let self else { return }
            self.handleSessionEvent(event)
            self.eventHandler?(event)
        }
        client.onConnectionFailure = { [weak self] error in
            self?.markDaemonFailed("daemon connection failed: \(error.localizedDescription)")
        }
    }

    /// App 启动时调用：spawn daemon、连接 socket、轮询 ping 直到 ready
    func warmUp() {
        precondition(Thread.isMainThread)
        guard !warming else { return }
        guard state != .ready, state != .starting, state != .listening, state != .stopping else { return }
        guard canAttemptRestartIfNeeded() else { return }
        isShuttingDown = false
        warming = true
        warmUpEpoch &+= 1
        let epoch = warmUpEpoch
        state = .loading

        ensureDaemonReady(epoch: epoch) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.warmUpEpoch == epoch else { return }
                self.warming = false
                switch result {
                case .success:
                    self.consecutiveRestartFailures = 0
                    self.sessionLifecycle.daemonReady()
                case let .failure(error):
                    self.markDaemonFailed(error.localizedDescription)
                }
            }
        }
    }

    /// Commands express intent. Only daemon acknowledgements change confirmed session state.
    func startSession() {
        precondition(Thread.isMainThread)
        switch state {
        case .ready, .starting, .listening, .stopping:
            sessionLifecycle.setDesiredListening(true)
        case .idle, .loading, .error:
            onSessionFailure?("ASR daemon 尚未就绪，请等待模型加载或重启服务。")
        }
    }

    func stopSession() {
        precondition(Thread.isMainThread)
        sessionLifecycle.setDesiredListening(false)
    }

    func discardCurrentUtterance(sessionID: String, before timestamp: TimeInterval) {
        guard clientConnected else { return }
        client.send(cmd: "discard_utterance", extra: ["session_id": sessionID, "before": timestamp])
    }

    /// 把设置页的断句等待 / live 刷新推到已运行的 daemon（不重启、不换模型）。
    func pushRuntimeDictationSettings() {
        guard clientConnected else { return }
        client.send(
            cmd: "config_update",
            extra: [
                "partial_interval_seconds": ConfigManager.shared.partialIntervalSeconds,
                "vad_end_silence_seconds": ConfigManager.shared.vadEndSilenceSeconds,
            ]
        )
        AppLogger.log(
            "config_update pushed partial=\(ConfigManager.shared.partialIntervalSeconds) vad_end=\(ConfigManager.shared.vadEndSilenceSeconds)"
        )
    }

    /// App 退出时结束 session、通知 daemon shutdown 并断开连接
    func shutdown() {
        isShuttingDown = true
        warmUpEpoch &+= 1
        warming = false
        pendingWarmUpAfterBackoff = false
        if state == .listening {
            stopSession()
        }
        sessionLifecycle.cancel()
        if clientConnected {
            client.send(cmd: "shutdown")
            Thread.sleep(forTimeInterval: 0.3)
            client.disconnect()
            clientConnected = false
        }
        if let proc = daemonProcess, proc.isRunning {
            let deadline = Date().addingTimeInterval(3.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if proc.isRunning {
                AppLogger.log("daemon_shutdown timeout; terminating pid=\(proc.processIdentifier)", level: "WARN")
                proc.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                if proc.isRunning {
                    AppLogger.log("daemon_shutdown SIGKILL pid=\(proc.processIdentifier)", level: "ERROR")
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        daemonProcess = nil
        removeStaleSocket()
        AppLogger.log("daemon_shutdown")
    }

    private func handleSessionEvent(_ event: DaemonEvent) {
        precondition(Thread.isMainThread)
        switch event.type {
        case "session_started":
            if let sessionID = event.sessionID {
                let resumed = event.raw["resumed"] as? Bool == true
                let cutoff = resumed ? Date().timeIntervalSince1970 : nil
                if sessionLifecycle.sessionStarted(sessionID, resumedAt: cutoff) {
                    if let cutoff {
                        discardCurrentUtterance(sessionID: sessionID, before: cutoff)
                    }
                    AppLogger.log("live_dictation_started session=\(sessionID) resumed=\(resumed)")
                }
            }
        case "session_stopped":
            if let sessionID = event.sessionID { sessionLifecycle.sessionStopped(sessionID) }
        case "error":
            let message = event.message ?? "ASR daemon error"
            if event.code == "mic_open_failed" {
                sessionLifecycle.microphoneOpenFailed(message)
            } else {
                markDaemonFailed(message)
            }
        default:
            break
        }
    }

    private func applySessionPhase() {
        let next: DaemonState
        switch sessionLifecycle.phase {
        case .ready: next = .ready
        case .starting: next = .starting
        case .listening: next = .listening
        case .stopping: next = .stopping
        case .failed(let message): next = .error(message)
        }
        if state == next { onStateChange?(state) } // A queued restart changes the menu action.
        else { state = next }
    }

    // MARK: - 内部：spawn + ping 轮询

    private func removeStaleSocket() {
        let path = ProjectPaths.socketPath.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(at: ProjectPaths.socketPath)
        AppLogger.log("removed stale socket", level: "WARN")
    }

    private func canAttemptRestartIfNeeded() -> Bool {
        guard case .error = state else { return true }
        if consecutiveRestartFailures >= maxRestartFailures {
            state = .error("daemon 连续失败 \(maxRestartFailures) 次，已停止自动重启；请检查 log/daemon.log")
            return false
        }
        let elapsed = Date().timeIntervalSince(lastRestartFailureAt)
        guard elapsed < restartBackoffSeconds else { return true }
        guard !pendingWarmUpAfterBackoff else { return false }

        pendingWarmUpAfterBackoff = true
        let delay = restartBackoffSeconds - elapsed
        AppLogger.log("daemon_restart_backoff delay=\(String(format: "%.2f", delay))s", level: "WARN")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingWarmUpAfterBackoff, !self.isShuttingDown else { return }
            self.pendingWarmUpAfterBackoff = false
            self.warmUp()
        }
        return false
    }

    private func recordRestartFailure(_ message: String) {
        consecutiveRestartFailures += 1
        lastRestartFailureAt = Date()
        sessionLifecycle.daemonFailed(message)
    }

    private func markDaemonFailed(_ message: String) {
        Self.onMain { [weak self] in
            guard let self else { return }
            guard !self.isShuttingDown else { return }
            if case .error = self.state { return }
            self.warmUpEpoch &+= 1
            self.warming = false
            self.clientConnected = false
            self.client.disconnect()
            if let proc = self.daemonProcess, proc.isRunning {
                AppLogger.log("daemon_failure terminating stale pid=\(proc.processIdentifier)", level: "WARN")
                proc.terminate()
            }
            self.daemonProcess = nil
            self.removeStaleSocket()
            self.recordRestartFailure(message)
        }
    }

    private func ensureDaemonReady(epoch: UInt64, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isCurrentWarmUp(epoch) else { return }
        let deadline = Date().addingTimeInterval(120)
        if FileManager.default.fileExists(atPath: ProjectPaths.socketPath.path) {
            connectAndPing(deadline: deadline, epoch: epoch, completion: completion)
            return
        }
        spawnDaemonAndWait(deadline: deadline, epoch: epoch, completion: completion)
    }

    private func spawnDaemonAndWait(deadline: Date, epoch: UInt64, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isCurrentWarmUp(epoch) else { return }
        launchDaemon { [weak self] launchError in
            guard let self, self.isCurrentWarmUp(epoch) else { return }
            if let launchError {
                completion(.failure(launchError))
                return
            }
            self.waitForSocketThenPing(deadline: deadline, epoch: epoch, completion: completion)
        }
    }

    private func launchDaemon(completion: @escaping (Error?) -> Void) {
        guard case let .success(root) = ProjectPaths.locateRepoRoot() else {
            completion(NSError(domain: "DaemonManager", code: 9, userInfo: [
                NSLocalizedDescriptionKey: ProjectPaths.LocateError.repositoryNotFound.localizedDescription,
            ]))
            return
        }

        let python = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.fileExists(atPath: python.path) else {
            completion(NSError(domain: "DaemonManager", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Python venv not found. Run ./scripts/setup_env.sh first.",
            ]))
            return
        }

        let task = Process()
        task.executableURL = python
        task.arguments = ["-m", "asr_daemon", "--model", ConfigManager.shared.asrModel]
        task.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = root.path
        env["MACOSASR_ROOT"] = root.path
        env["MACOSASR_PARTIAL_INTERVAL"] = String(format: "%.2f", ConfigManager.shared.partialIntervalSeconds)
        env["MACOSASR_VAD_END_SILENCE"] = String(format: "%.2f", ConfigManager.shared.vadEndSilenceSeconds)
        task.environment = env
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] process in
            self?.handleDaemonTermination(process)
        }

        do {
            try task.run()
            daemonProcess = task
            AppLogger.log("spawned asr_daemon pid=\(task.processIdentifier)")
            completion(nil)
        } catch {
            completion(error)
        }
    }

    private func handleDaemonTermination(_ process: Process) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let daemonProcess = self.daemonProcess, daemonProcess === process else { return }
            guard !self.isShuttingDown else { return }
            self.markDaemonFailed("asr_daemon exited unexpectedly status=\(process.terminationStatus)")
        }
    }

    private func waitForSocketThenPing(deadline: Date, epoch: UInt64, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isCurrentWarmUp(epoch) else { return }
        if Date() > deadline {
            completion(.failure(NSError(domain: "DaemonManager", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "等待 daemon socket 超时",
            ])))
            return
        }
        if FileManager.default.fileExists(atPath: ProjectPaths.socketPath.path) {
            connectAndPing(deadline: deadline, epoch: epoch, completion: completion)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForSocketThenPing(deadline: deadline, epoch: epoch, completion: completion)
        }
    }

    private func connectAndPing(deadline: Date, epoch: UInt64, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isCurrentWarmUp(epoch) else { return }
        if Date() > deadline {
            completion(.failure(NSError(domain: "DaemonManager", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "daemon 模型加载/校准超时（约 120s）",
            ])))
            return
        }

        if !clientConnected {
            do {
                try client.connect(socketPath: ProjectPaths.socketPath)
                clientConnected = true
            } catch {
                // socket 文件在但 daemon 已退出 → 清掉残留并重新 spawn
                AppLogger.log("daemon_connect_failed will respawn", level: "WARN")
                removeStaleSocket()
                client.disconnect()
                clientConnected = false
                spawnDaemonAndWait(deadline: deadline, epoch: epoch, completion: completion)
                return
            }
        }

        client.ping { [weak self] result in
            Self.onMain {
                guard let self, self.isCurrentWarmUp(epoch) else { return }
                switch result {
                case let .success(event):
                    if event.modelLoaded == true, event.calibrated == true {
                        self.pushRuntimeDictationSettings()
                        completion(.success(()))
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.connectAndPing(deadline: deadline, epoch: epoch, completion: completion)
                        }
                    }
                case .failure:
                    self.clientConnected = false
                    self.client.disconnect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.connectAndPing(deadline: deadline, epoch: epoch, completion: completion)
                    }
                }
            }
        }
    }

    private func isCurrentWarmUp(_ epoch: UInt64) -> Bool {
        precondition(Thread.isMainThread)
        return warming && warmUpEpoch == epoch && !isShuttingDown
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
