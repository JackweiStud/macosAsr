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
    var asrModel: String { config.asrModel }
    var partialIntervalSeconds: Double { config.partialIntervalSeconds }
    var vadEndSilenceSeconds: Double { config.vadEndSilenceSeconds }

    func saveLanguage(_ language: String) throws {
        guard RecognitionLanguage(asrValue: language) != nil else {
            throw ConfigError.invalidLanguage
        }
        config.language = language
        try save()
        AppLogger.log("config_saved language=\(language) path=\(configURL.path)")
    }

    func saveAdvancedDictationSettings(
        asrModel: String,
        partialIntervalSeconds: Double,
        vadEndSilenceSeconds: Double
    ) throws {
        guard AsrModelPreset.allCases.contains(where: { $0.rawValue == asrModel }) else {
            throw ConfigError.invalidAsrModel
        }
        guard PartialIntervalPreset.allCases.contains(where: { $0.rawValue == partialIntervalSeconds }) else {
            throw ConfigError.invalidPartialInterval
        }
        guard VadEndSilencePreset.allCases.contains(where: { $0.rawValue == vadEndSilenceSeconds }) else {
            throw ConfigError.invalidVadEndSilence
        }
        config.asrModel = asrModel
        config.partialIntervalSeconds = partialIntervalSeconds
        config.vadEndSilenceSeconds = vadEndSilenceSeconds
        try save()
        AppLogger.log(
            "config_saved asr_model=\(asrModel) partial_interval=\(partialIntervalSeconds) vad_end_silence=\(vadEndSilenceSeconds) path=\(configURL.path)"
        )
    }

    // MARK: - Private

    private enum ConfigError: LocalizedError {
        case invalidLanguage
        case invalidAsrModel
        case invalidPartialInterval
        case invalidVadEndSilence

        var errorDescription: String? {
            switch self {
            case .invalidLanguage: return "不支持的识别语言"
            case .invalidAsrModel: return "不支持的 ASR 模型"
            case .invalidPartialInterval: return "不支持的实时文字刷新速度"
            case .invalidVadEndSilence: return "不支持的断句等待时间"
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
