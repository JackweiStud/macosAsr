import Foundation

// Compile-time boundaries for the Manager integration self-test. No live socket,
// configuration file, application log, microphone, or CGEvent is accessed.
enum AppLogger {
    static func log(_ message: String, level: String = "INFO") {}
}

final class ConfigManager {
    static let shared = ConfigManager()
    let language = "Chinese"
    let asrModel = "selftest-no-model"
    let partialIntervalSeconds = 0.8
    let vadEndSilenceSeconds = 1.5
}

enum ProjectPaths {
    enum LocateError: LocalizedError {
        case repositoryNotFound
        var errorDescription: String? { "self-test must never spawn a real daemon" }
    }
    static var socketPath: URL {
        guard let path = ProcessInfo.processInfo.environment["MACOSASR_SELFTEST_SOCKET"],
              path.contains("session-manager-selftest-")
        else { fatalError("dedicated self-test socket path is required") }
        return URL(fileURLWithPath: path)
    }
    static func locateRepoRoot() -> Result<URL, LocateError> { .failure(.repositoryNotFound) }
}

/// A controllable IPC boundary. It deliberately allows obsolete command/ping
/// completions to run so production Manager/Lifecycle epoch guards are exercised.
/// Connection-generation filtering belongs to the real DaemonClient and is not
/// reimplemented (or claimed as verified) by this fake.
final class DaemonClient {
    struct Sent {
        let command: String
        let extra: [String: Any]
        let completion: ((Result<Void, Error>) -> Void)?
    }
    static var latest: DaemonClient?
    var onEvent: ((DaemonEvent) -> Void)?
    var onConnectionFailure: ((Error) -> Void)?
    private(set) var sent: [Sent] = []
    private(set) var pingReplies: [(Result<DaemonEvent, Error>) -> Void] = []
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var connected = false

    init() { Self.latest = self }

    func connect(socketPath: URL) throws {
        precondition(Thread.isMainThread)
        precondition(socketPath == ProjectPaths.socketPath)
        precondition(FileManager.default.fileExists(atPath: socketPath.path))
        connectCount += 1
        connected = true
    }
    func disconnect() {
        disconnectCount += 1
        connected = false
    }
    func ping(completion: @escaping (Result<DaemonEvent, Error>) -> Void) {
        precondition(connected)
        pingReplies.append(completion)
    }
    func send(cmd: String, extra: [String: Any] = [:], completion: ((Result<Void, Error>) -> Void)? = nil) {
        precondition(connected, "Manager sent a command without connecting")
        sent.append(Sent(command: cmd, extra: extra, completion: completion))
    }
    func emit(_ type: String, raw: [String: Any] = [:]) {
        precondition(Thread.isMainThread)
        onEvent?(DaemonEvent(type: type, raw: raw))
    }
    func commands(_ name: String) -> [Sent] { sent.filter { $0.command == name } }
}
