import Foundation

/// 读写 ~/Library/Application Support/macosAsr/config.json
final class ConfigManager {
    static let shared = ConfigManager()

    private(set) var config: AppConfig

    private let configURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("macosAsr", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("config.json")
        config = Self.load(from: configURL) ?? AppConfig.defaults
    }

    var language: String { config.language }

    func saveLanguage(_ language: String) throws {
        guard RecognitionLanguage(asrValue: language) != nil else {
            throw ConfigError.invalidLanguage
        }
        config.language = language
        try save()
        AppLogger.log("config_saved language=\(language) path=\(configURL.path)")
    }

    // MARK: - Private

    private enum ConfigError: LocalizedError {
        case invalidLanguage

        var errorDescription: String? {
            switch self {
            case .invalidLanguage: return "不支持的识别语言"
            }
        }
    }

    private static func load(from url: URL) -> AppConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppConfig.self, from: data)
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
    }
}
