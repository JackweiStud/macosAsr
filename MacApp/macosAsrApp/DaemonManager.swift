import Foundation

/// Ensures asr_daemon is running and reachable (P0d).
final class DaemonManager {
    static let shared = DaemonManager()

    private var daemonProcess: Process?
    private let client = DaemonClient()
    private var clientConnected = false

    var eventHandler: ((DaemonEvent) -> Void)? {
        get { client.onEvent }
        set { client.onEvent = newValue }
    }

    private init() {}

    func ensureDaemonReady(completion: @escaping (Result<Void, Error>) -> Void) {
        let deadline = Date().addingTimeInterval(90)
        if FileManager.default.fileExists(atPath: ProjectPaths.socketPath.path) {
            connectAndPing(deadline: deadline, completion: completion)
            return
        }
        launchDaemon { [weak self] launchError in
            if let launchError {
                completion(.failure(launchError))
                return
            }
            self?.waitForSocketThenPing(deadline: deadline, completion: completion)
        }
    }

    func sendSessionStart(language: String = "Chinese") {
        client.send(cmd: "session_start", extra: ["language": language])
    }

    func sendSessionStop() {
        client.send(cmd: "session_stop")
    }

    private func launchDaemon(completion: @escaping (Error?) -> Void) {
        let python = ProjectPaths.venvPython
        guard FileManager.default.fileExists(atPath: python.path) else {
            completion(NSError(domain: "DaemonManager", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "未找到 .venv：请先运行 ./scripts/setup_env.sh",
            ]))
            return
        }

        let task = Process()
        task.executableURL = python
        task.arguments = ["-m", "asr_daemon"]
        task.currentDirectoryURL = ProjectPaths.repoRoot
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = ProjectPaths.repoRoot.path
        task.environment = env
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            daemonProcess = task
            AppLogger.log("spawned asr_daemon pid=\(task.processIdentifier)")
            completion(nil)
        } catch {
            completion(error)
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
                NSLocalizedDescriptionKey: "daemon 模型加载/校准超时（约 90s）",
            ])))
            return
        }

        if !clientConnected {
            do {
                try client.connect(socketPath: ProjectPaths.socketPath)
                clientConnected = true
            } catch {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.connectAndPing(deadline: deadline, completion: completion)
                }
                return
            }
        }

        client.ping { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(event):
                if event.modelLoaded == true, event.calibrated == true {
                    completion(.success(()))
                } else {
                    AppLogger.log(
                        "daemon_warming model_loaded=\(event.modelLoaded ?? false) "
                            + "calibrated=\(event.calibrated ?? false)"
                    )
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.connectAndPing(deadline: deadline, completion: completion)
                    }
                }
            case .failure:
                // 保持连接，等待 daemon 就绪后再 ping（避免反复 disconnect 丢 pong）
                self.clientConnected = false
                self.client.disconnect()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    self.connectAndPing(deadline: deadline, completion: completion)
                }
            }
        }
    }
}
