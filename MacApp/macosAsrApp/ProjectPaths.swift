import Foundation

enum ProjectPaths {
    enum LocateError: LocalizedError {
        case repositoryNotFound

        var errorDescription: String? {
            """
            Cannot locate the macosAsr repository.
            Launch with ./scripts/launch_macapp.sh or set MACOSASR_ROOT to your clone path.
            """
        }
    }

    static func locateRepoRoot() -> Result<URL, LocateError> {
        if let env = ProcessInfo.processInfo.environment["MACOSASR_ROOT"], !env.isEmpty {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            if isValidRepoRoot(url) { return .success(url) }
        }

        // MacApp/build/macosAsrApp.app → three levels up to repo root
        var candidate = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if isValidRepoRoot(candidate) { return .success(candidate) }

        // Walk up from the app bundle (covers non-standard install layouts)
        candidate = Bundle.main.bundleURL
        for _ in 0 ..< 8 {
            if isValidRepoRoot(candidate) { return .success(candidate) }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }

        return .failure(.repositoryNotFound)
    }

    static var repoRoot: URL {
        switch locateRepoRoot() {
        case let .success(url):
            return url
        case let .failure(error):
            fatalError(error.localizedDescription)
        }
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

    private static func isValidRepoRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("asr_daemon").path)
            && fm.fileExists(atPath: url.appendingPathComponent("asr").path)
    }
}
