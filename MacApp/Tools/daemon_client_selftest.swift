import Darwin
import Foundation

// Only the real socket client is under test; these dependencies never touch logs or UI.
struct DictationUtterance: Equatable {
    let sessionID: String
    let utteranceID: Int
    let startedAt: TimeInterval
}
enum AppLogger {
    static func log(_ message: String, level: String = "INFO") {}
}

private final class LockedBox<Value> {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { locked { $0 } }
    func mutate(_ work: (inout Value) -> Void) { locked { work(&$0) } }
    private func locked<T>(_ work: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return work(&value)
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
private func listeningSocket(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    check(fd >= 0, "cannot create fake server socket")
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString
    check(bytes.count <= MemoryLayout.size(ofValue: address.sun_path), "temporary socket path too long")
    _ = withUnsafeMutablePointer(to: &address.sun_path.0) { target in
        bytes.withUnsafeBytes { memcpy(target, $0.baseAddress!, $0.count) }
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    check(bound == 0 && listen(fd, 1) == 0, "cannot bind/listen fake server")
    return fd
}
private func writeEvent(_ fd: Int32, _ event: [String: Any]) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: event) else { return false }
    let line = data + Data([10])
    return line.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count <= 0 { return false }
            offset += count
        }
        return true
    }
}

@main
struct DaemonClientSelfTest {
    static func main() throws {
        let directory = URL(fileURLWithPath: "/tmp/asrc-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pathA = directory.appendingPathComponent("a.sock")
        let pathB = directory.appendingPathComponent("b.sock")
        let serverA = listeningSocket(pathA.path)
        let serverB = listeningSocket(pathB.path)
        defer { close(serverA); close(serverB) }
        let aWriteReachedKernel = DispatchSemaphore(value: 0)
        let closeA = DispatchSemaphore(value: 0)
        let aDone = DispatchSemaphore(value: 0)
        let closeB = DispatchSemaphore(value: 0)
        let bDone = DispatchSemaphore(value: 0)
        let serverErrors = LockedBox<[String]>([])
        let commandsB = LockedBox<[[String: Any]]>([])

        DispatchQueue.global().async {
            defer { aDone.signal() }
            let peer = accept(serverA, nil, nil)
            guard peer >= 0 else { serverErrors.mutate { $0.append("A accept failed") }; return }
            defer { close(peer) }
            var bufferSize: Int32 = 4096
            _ = setsockopt(peer, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
            var byte: UInt8 = 0
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if recv(peer, &byte, 1, MSG_PEEK | MSG_DONTWAIT) > 0 {
                    aWriteReachedKernel.signal()
                    _ = closeA.wait(timeout: .now() + 3)
                    return // Close A while its large client write is still in flight.
                }
                usleep(1000)
            }
            serverErrors.mutate { $0.append("A write never reached kernel") }
        }
        DispatchQueue.global().async {
            defer { bDone.signal() }
            let peer = accept(serverB, nil, nil)
            guard peer >= 0 else { serverErrors.mutate { $0.append("B accept failed") }; return }
            defer { close(peer) }
            var noSigPipe: Int32 = 1
            _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while commandsB.get().count < 2 {
                let count = read(peer, &bytes, bytes.count)
                if count <= 0 { serverErrors.mutate { $0.append("B closed before receiving commands") }; return }
                pending.append(contentsOf: bytes.prefix(count))
                if pending.count > 1_048_576 { serverErrors.mutate { $0.append("old large A payload reached B") }; return }
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        serverErrors.mutate { $0.append("invalid command JSON") }; return
                    }
                    commandsB.mutate { $0.append(object) }
                    let command = object["cmd"] as? String
                    let type = command == "ping" ? "pong" : "config_updated"
                    if !writeEvent(peer, ["protocol": 1, "type": type, "model_loaded": true, "calibrated": true]) {
                        serverErrors.mutate { $0.append("B reply failed") }; return
                    }
                }
            }
            _ = closeB.wait(timeout: .now() + 3)
        }

        let client = DaemonClient()
        var events: [String] = []
        var failures: [String] = []
        var callbackOffMain = false
        var pingConfirmed = false
        let aWriteFinished = LockedBox(false)
        let oldQueuedWriteFinished = LockedBox(false)
        client.onEvent = { event in
            callbackOffMain = callbackOffMain || !Thread.isMainThread
            events.append(event.type)
        }
        client.onConnectionFailure = { error in
            callbackOffMain = callbackOffMain || !Thread.isMainThread
            failures.append(error.localizedDescription)
        }
        try client.connect(socketPath: pathA)
        client.send(cmd: "blocked_a", extra: ["payload": String(repeating: "x", count: 8 * 1024 * 1024)]) { _ in
            aWriteFinished.mutate { $0 = true }
        }
        check(aWriteReachedKernel.wait(timeout: .now() + 2) == .success, "A did not enter a real blocked socket write")
        check(!aWriteFinished.get(), "A write was not blocked; reconnect scenario is invalid")
        client.send(cmd: "queued_old_a") { _ in oldQueuedWriteFinished.mutate { $0 = true } }
        client.disconnect()
        try client.connect(socketPath: pathB)
        client.ping { result in
            callbackOffMain = callbackOffMain || !Thread.isMainThread
            if case .success(let event) = result { pingConfirmed = event.type == "pong" }
        }
        client.send(cmd: "config_update", extra: ["partial_interval_seconds": 0.8, "vad_end_silence_seconds": 1.5])
        closeA.signal()
        pump(until: { pingConfirmed && events.contains("config_updated") }, "B did not receive healthy responses after reconnect")
        pump(until: { aWriteFinished.get() && oldQueuedWriteFinished.get() }, "old A writes never completed")
        check(serverErrors.get().isEmpty, "fake server errors: \(serverErrors.get())")
        let commands = commandsB.get()
        check(commands.compactMap { $0["cmd"] as? String } == ["ping", "config_update"], "old A command contaminated B")
        check(failures.isEmpty, "old A failure closed healthy B: \(failures)")
        print("PASS: reconnect isolates blocked/queued A writes and stale failures from B")

        check(commands.allSatisfy { $0["protocol"] as? Int == 1 }, "missing protocol version")
        check(commands[1]["partial_interval_seconds"] as? Double == 0.8, "config partial interval changed")
        check(commands[1]["vad_end_silence_seconds"] as? Double == 1.5, "config silence interval changed")
        check(events == ["pong", "config_updated"] && !callbackOffMain, "normal events/ping did not arrive on main")
        print("PASS: real ping/config JSON and ordered main-thread callbacks")

        closeB.signal()
        pump(until: { failures.count == 1 }, "current B EOF did not report connection failure")
        check(!callbackOffMain, "current connection failure callback ran off main")
        client.disconnect()
        check(aDone.wait(timeout: .now() + 1) == .success && bDone.wait(timeout: .now() + 1) == .success,
              "fake server threads did not finish")
        print("PASS: current peer closure reports exactly one main-thread connection failure")
        print("PASS: production DaemonClient isolated Unix socket self-test (3 cases)")
    }
}
