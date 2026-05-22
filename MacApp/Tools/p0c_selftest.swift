#!/usr/bin/swift
/// P0c headless self-test — compile + state machine + logging (no GUI / no Accessibility).
import Foundation

protocol TextInjecting: AnyObject {
    func backspace(count: Int)
    func typeText(_ text: String)
}

final class RecordingInjector: TextInjecting {
    var backspaces: [Int] = []
    var typed: [String] = []

    func backspace(count: Int) { backspaces.append(count) }
    func typeText(_ text: String) { typed.append(text) }
}

final class InjectionStateMachine {
    private let injector: TextInjecting
    private(set) var pendingLen: Int = 0

    init(injector: TextInjecting) {
        self.injector = injector
    }

    func onPartial(_ text: String) {
        injector.backspace(count: pendingLen)
        injector.typeText(text)
        pendingLen = text.count
    }

    func onFinal(_ text: String) { onPartial(text) }

    func onFiltered() {
        injector.backspace(count: pendingLen)
        pendingLen = 0
    }

    func onSessionStopped() { pendingLen = 0 }
}

enum ProjectPaths {
    static var repoRoot: URL {
        if let env = ProcessInfo.processInfo.environment["MACOSASR_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    static var logFile: URL { repoRoot.appendingPathComponent("log/macapp-selftest.log") }
}

enum AppLogger {
    static func log(_ message: String) -> Bool {
        let line = "\(ISO8601DateFormatter().string(from: Date())) INFO \(message)\n"
        guard let data = line.data(using: .utf8) else { return false }
        let url = ProjectPaths.logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

let injector = RecordingInjector()
let sm = InjectionStateMachine(injector: injector)
let steps = ["你好世", "你好世界", "你好，世界。"]

sm.onSessionStopped()
for (i, text) in steps.enumerated() {
    if i == steps.count - 1 {
        sm.onFinal(text)
    } else {
        sm.onPartial(text)
    }
}
sm.onSessionStopped()

guard injector.backspaces == [0, 3, 4] else {
    fail("backspaces expected [0,3,4] got \(injector.backspaces)")
}
guard injector.typed == steps else {
    fail("typed mismatch got \(injector.typed)")
}
guard sm.pendingLen == 0 else {
    fail("pendingLen should be 0 after session_stopped")
}

let logOk = AppLogger.log("p0c_selftest state_machine PASS")
guard logOk else { fail("log write failed") }

print("PASS: P0c state machine backspace/retype logic")
print("PASS: log written to \(ProjectPaths.logFile.path)")
print("NOTE: GUI injection in Notes still requires manual run of macosAsrApp.app (Accessibility)")
