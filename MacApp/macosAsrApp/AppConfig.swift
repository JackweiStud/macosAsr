import Foundation

/// 用户可配置项（持久化至 Application Support）。
struct AppConfig: Codable, Equatable {
    var language: String

    static let defaultLanguage = "Chinese"

    static var defaults: AppConfig {
        AppConfig(language: defaultLanguage)
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
