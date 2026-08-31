import Darwin
import Foundation

/// 守护进程状态（单一事实源，驱动菜单栏 UI）
enum DaemonState: Equatable {
    case idle           // 尚未启动
    case loading        // 已 spawn / 正在加载模型 / 校准中
    case ready          // 已就绪，可开始听写
    case listening      // 听写中（session_started）
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
    private var sessionStartEpoch = 0

    private(set) var state: DaemonState = .idle {
        didSet {
            if oldValue != state {
                AppLogger.log("daemon_state \(oldValue) -> \(state)")
                let s = state
                DispatchQueue.main.async { [weak self] in
                    self?.onStateChange?(s)
                }
            }
        }
    }

    /// 状态变化回调，主线程触发
    var onStateChange: ((DaemonState) -> Void)?

    var eventHandler: ((DaemonEvent) -> Void)? {
        get { client.onEvent }
        set { client.onEvent = newValue }
    }

    private init() {
        client.onConnectionFailure = { [weak self] error in
            self?.markDaemonFailed("daemon connection failed: \(error.localizedDescription)")
        }
    }

    /// App 启动时调用：spawn daemon、连接 socket、轮询 ping 直到 ready
    func warmUp() {
        guard !warming else { return }
        guard state != .ready, state != .listening else { return }
        guard canAttemptRestartIfNeeded() else { return }
        isShuttingDown = false
        warming = true
        state = .loading

        ensureDaemonReady { [weak self] result in
            guard let self else { return }
            self.warming = false
            switch result {
            case .success:
                self.consecutiveRestartFailures = 0
                if self.state != .listening { self.state = .ready }
            case let .failure(error):
                self.recordRestartFailure(error.localizedDescription)
            }
        }
    }

    /// 当 daemon 已 ready 时直接发 session_start；否则尝试 warmUp 后再开
    func startSession(completion: @escaping (Result<Void, Error>) -> Void) {
        let language = ConfigManager.shared.language
        switch state {
        case .ready:
            sendSessionStart(language: language, completion: completion)
        case .listening:
            completion(.success(()))
        case .idle, .loading, .error:
            warmUp()
            // 等待 ready 后再发；这里给回调一个超时机制由调用方决定
            waitForReady(deadline: Date().addingTimeInterval(120)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.sendSessionStart(language: language, completion: completion)
                case let .failure(err):
                    completion(.failure(err))
                }
            }
        }
    }

    func stopSession() {
        sessionStartEpoch += 1
        guard state == .listening else { return }
        client.send(cmd: "session_stop")
        state = .ready
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
        if state == .listening {
            stopSession()
        }
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

    /// session 因开麦失败等错误结束时调用：取消 in-flight 的 session_start 成功回调
    func revertListeningAfterError() {
        sessionStartEpoch += 1
        if state == .listening { state = .ready }
    }

    /// session_stopped 事件回调时由 LiveDictationController 调用
    func notifySessionStoppedFromDaemon() {
        sessionStartEpoch += 1
        if state == .listening { state = .ready }
    }

    // MARK: - 内部：等待 ready

    private func waitForReady(deadline: Date, completion: @escaping (Result<Void, Error>) -> Void) {
        if state == .ready || state == .listening {
            completion(.success(()))
            return
        }
        if case .error(let msg) = state {
            completion(.failure(NSError(domain: "DaemonManager", code: 20, userInfo: [
                NSLocalizedDescriptionKey: msg,
            ])))
            return
        }
        if Date() > deadline {
            completion(.failure(NSError(domain: "DaemonManager", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "等待 daemon 就绪超时",
            ])))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForReady(deadline: deadline, completion: completion)
        }
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
            guard let self else { return }
            self.pendingWarmUpAfterBackoff = false
            self.warmUp()
        }
        return false
    }

    private func recordRestartFailure(_ message: String) {
        consecutiveRestartFailures += 1
        lastRestartFailureAt = Date()
        state = .error(message)
    }

    private func markDaemonFailed(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.isShuttingDown else { return }
            if case .error = self.state { return }
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

    private func sendSessionStart(language: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let epoch = sessionStartEpoch
        client.send(cmd: "session_start", extra: ["language": language]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard epoch == self.sessionStartEpoch else { return }
                switch result {
                case .success:
                    self.state = .listening
                    completion(.success(()))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func ensureDaemonReady(completion: @escaping (Result<Void, Error>) -> Void) {
        let deadline = Date().addingTimeInterval(120)
        if FileManager.default.fileExists(atPath: ProjectPaths.socketPath.path) {
            connectAndPing(deadline: deadline, completion: completion)
            return
        }
        spawnDaemonAndWait(deadline: deadline, completion: completion)
    }

    private func spawnDaemonAndWait(deadline: Date, completion: @escaping (Result<Void, Error>) -> Void) {
        launchDaemon { [weak self] launchError in
            if let launchError {
                completion(.failure(launchError))
                return
            }
            self?.waitForSocketThenPing(deadline: deadline, completion: completion)
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

    private func waitForSocketThenPing(deadline: Date, completion: @escaping (Result<Void, Error>) -> Void) {
        if Date() > deadline {
            completion(.failure(NSError(domain: "DaemonManager", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "等待 daemon socket 超时",
            ])))
            return
        }
        if FileManager.default.fileExists(atPath: ProjectPaths.socketPath.path) {
            connectAndPing(deadline: deadline, completion: completion)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForSocketThenPing(deadline: deadline, completion: completion)
        }
    }

    private func connectAndPing(deadline: Date, completion: @escaping (Result<Void, Error>) -> Void) {
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
                spawnDaemonAndWait(deadline: deadline, completion: completion)
                return
            }
        }

        client.ping { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(event):
                if event.modelLoaded == true, event.calibrated == true {
                    self.pushRuntimeDictationSettings()
                    completion(.success(()))
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.connectAndPing(deadline: deadline, completion: completion)
                    }
                }
            case .failure:
                self.clientConnected = false
                self.client.disconnect()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    self.connectAndPing(deadline: deadline, completion: completion)
                }
            }
        }
    }
}
