import Foundation

enum ProjectPaths {
    static var repoRoot: URL {
        if let env = ProcessInfo.processInfo.environment["MACOSASR_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        // MacApp/build/macosAsrApp.app → 上三级为仓库根
        let bundle = Bundle.main.bundleURL
        let derived = bundle
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: derived.appendingPathComponent("asr_daemon").path) {
            return derived
        }
        return URL(fileURLWithPath: "/Users/jackwl/Code/macosAsr")
    }

    static var logFile: URL {
        repoRoot.appendingPathComponent("log/macapp.log")
    }

    static var socketPath: URL {
        repoRoot.appendingPathComponent("run/macosasr.sock")
    }

    static var venvPython: URL {
        repoRoot.appendingPathComponent(".venv/bin/python")
    }
}
