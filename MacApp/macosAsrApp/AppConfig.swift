import Foundation

/// 用户可配置项（持久化至 Application Support）。
struct AppConfig: Codable, Equatable {
    var language: String
    var asrModel: String
    var partialIntervalSeconds: Double
    var vadEndSilenceSeconds: Double
    var customHotwords: String
    var screenContextEnabled: Bool
    var oralPolishEnabled: Bool

    static let defaultLanguage = "Chinese"
    static let defaultAsrModel = AsrModelPreset.qwen06B.rawValue
    static let defaultPartialIntervalSeconds = 0.5
    static let defaultVadEndSilenceSeconds = 1.5
    static let defaultCustomHotwords = "macosAsr, Qwen3-ASR, MLX, FastAPI, PostgreSQL, Redis, WebSocket, REST API, TypeScript, Python, Swift, Git, GitHub, Git Commit, Pull Request, Docker, Kubernetes, Cursor, Codex, PartialEngine, VAD"
    static let defaultScreenContextEnabled = false
    static let defaultOralPolishEnabled = false

    static var defaults: AppConfig {
        AppConfig(
            language: defaultLanguage,
            asrModel: defaultAsrModel,
            partialIntervalSeconds: defaultPartialIntervalSeconds,
            vadEndSilenceSeconds: defaultVadEndSilenceSeconds,
            customHotwords: defaultCustomHotwords,
            screenContextEnabled: defaultScreenContextEnabled,
            oralPolishEnabled: defaultOralPolishEnabled
        )
    }

    init(
        language: String,
        asrModel: String = defaultAsrModel,
        partialIntervalSeconds: Double = defaultPartialIntervalSeconds,
        vadEndSilenceSeconds: Double = defaultVadEndSilenceSeconds,
        customHotwords: String = defaultCustomHotwords,
        screenContextEnabled: Bool = defaultScreenContextEnabled,
        oralPolishEnabled: Bool = defaultOralPolishEnabled
    ) {
        self.language = language
        self.asrModel = asrModel
        self.partialIntervalSeconds = partialIntervalSeconds
        self.vadEndSilenceSeconds = vadEndSilenceSeconds
        self.customHotwords = customHotwords
        self.screenContextEnabled = screenContextEnabled
        self.oralPolishEnabled = oralPolishEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case language
        case asrModel
        case partialIntervalSeconds
        case vadEndSilenceSeconds
        case customHotwords
        case screenContextEnabled
        case oralPolishEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? Self.defaultLanguage
        asrModel = try container.decodeIfPresent(String.self, forKey: .asrModel) ?? Self.defaultAsrModel
        partialIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .partialIntervalSeconds)
            ?? Self.defaultPartialIntervalSeconds
        vadEndSilenceSeconds = try container.decodeIfPresent(Double.self, forKey: .vadEndSilenceSeconds)
            ?? Self.defaultVadEndSilenceSeconds
        customHotwords = try container.decodeIfPresent(String.self, forKey: .customHotwords)
            ?? Self.defaultCustomHotwords
        screenContextEnabled = try container.decodeIfPresent(Bool.self, forKey: .screenContextEnabled)
            ?? Self.defaultScreenContextEnabled
        oralPolishEnabled = try container.decodeIfPresent(Bool.self, forKey: .oralPolishEnabled)
            ?? Self.defaultOralPolishEnabled
    }
}

enum AsrModelPreset: String, CaseIterable {
    case qwen06B = "mlx-community/Qwen3-ASR-0.6B-8bit"
    case qwen17B = "mlx-community/Qwen3-ASR-1.7B-8bit"

    var displayName: String {
        switch self {
        case .qwen06B: return "Qwen3-ASR 0.6B (default)"
        case .qwen17B: return "Qwen3-ASR 1.7B"
        }
    }
}

enum PartialIntervalPreset: Double, CaseIterable {
    case fast = 0.3
    case balanced = 0.5
    case stable = 0.8

    var displayName: String {
        switch self {
        case .fast: return "Faster (0.3s)"
        case .balanced: return "Balanced (0.5s)"
        case .stable: return "More stable (0.8s)"
        }
    }
}

enum VadEndSilencePreset: Double, CaseIterable {
    case quick = 0.6
    case balanced = 1.0
    case longForm = 1.5
    case thinking = 2.0

    var displayName: String {
        switch self {
        case .quick: return "Quick (0.6s)"
        case .balanced: return "Balanced (1.0s)"
        case .longForm: return "Long-form (1.5s)"
        case .thinking: return "Thinking (2.0s)"
        }
    }
}

enum RecognitionLanguage: String, CaseIterable {
    case chinese = "Chinese"
    case english = "English"

    var displayName: String {
        switch self {
        case .chinese: return "Chinese"
        case .english: return "English"
        }
    }

    init?(asrValue: String) {
        self.init(rawValue: asrValue)
    }
}

enum OralPolishPreset: String, CaseIterable {
    case off = "off"
    case localLLM = "local_llm"

    var isEnabled: Bool { self == .localLLM }

    var displayName: String {
        switch self {
        case .off: return "Off (default, raw dictation)"
        case .localLLM: return "Local LLM (rules + Qwen3 1.7B)"
        }
    }
}
