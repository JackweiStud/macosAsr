import Darwin
import Foundation

struct DaemonEvent {
    let type: String
    let raw: [String: Any]
    var text: String? { raw["text"] as? String }
    var message: String? { raw["message"] as? String }
    var modelLoaded: Bool? { raw["model_loaded"] as? Bool }
    var calibrated: Bool? { raw["calibrated"] as? Bool }
}

/// Unix socket JSON-lines client (SDD §5). Keeps one connection for session broadcasts.
final class DaemonClient {
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let writeQueue = DispatchQueue(label: "com.macosasr.daemon.write")
    private var lineBuffer = ""
    var onEvent: ((DaemonEvent) -> Void)?

    deinit {
        disconnect()
    }

    func connect(socketPath: URL) throws {
        disconnect()
        let path = socketPath.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NSError(domain: "DaemonClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket path too long"])
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            pathBytes.withUnsafeBytes { raw in
                memcpy(dst, raw.baseAddress!, min(raw.count, 104))
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ECONNREFUSED)
        }

        socketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        readSource = source
        AppLogger.log("daemon_client connected path=\(path)")
    }

    func disconnect() {
        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        lineBuffer = ""
    }

    func send(cmd: String, extra: [String: Any] = [:]) {
        var payload: [String: Any] = ["protocol": 1, "cmd": cmd]
        extra.forEach { payload[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        let fd = socketFD
        writeQueue.async {
            line.withUTF8 { raw in
                _ = write(fd, raw.baseAddress!, raw.count)
            }
        }
    }

    func ping(completion: @escaping (Result<DaemonEvent, Error>) -> Void) {
        let lock = NSLock()
        var finished = false
        let finish: (Result<DaemonEvent, Error>) -> Void = { result in
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            completion(result)
        }

        let prior = onEvent
        onEvent = { event in
            prior?(event)
            if event.type == "pong" {
                finish(.success(event))
            } else if event.type == "error" {
                finish(.failure(NSError(domain: "DaemonClient", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: event.message ?? "daemon error",
                ])))
            }
        }
        send(cmd: "ping")
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            finish(.failure(NSError(domain: "DaemonClient", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "ping timeout",
            ])))
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(socketFD, &chunk, chunk.count)
        guard n > 0 else { return }
        lineBuffer.append(String(decoding: chunk.prefix(n), as: UTF8.self))
        while let range = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer = String(lineBuffer[range.upperBound...])
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            let event = DaemonEvent(type: type, raw: obj)
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        }
    }
}
