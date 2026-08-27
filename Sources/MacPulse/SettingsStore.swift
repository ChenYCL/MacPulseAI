import Foundation
import Combine

/// 应用设置。字段全部有默认值；解码旧文件缺字段时回落默认值（decodeIfPresent）。
struct Settings: Codable, Equatable {
    enum ProviderKind: String, Codable, CaseIterable, Identifiable {
        case openAICompatible
        case anthropic

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .openAICompatible: return L10n.s("OpenAI 兼容", "OpenAI-Compatible")
            case .anthropic: return "Anthropic"
            }
        }
    }

    var provider: ProviderKind = .openAICompatible

    var openAIBaseURL = "https://api.openai.com/v1"
    var openAIModel = "gpt-4o-mini"
    var openAIAPIKey = ""

    var anthropicBaseURL = "https://api.anthropic.com"
    var anthropicModel = "claude-sonnet-4-5"
    var anthropicAPIKey = ""

    var refreshInterval: Double = 2
    var cpuHighlightThreshold: Double = 50
    var topProcessesToSend: Int = 25
    var includeProcessPath = true
    /// 界面语言："auto"（跟随系统）/ "zh" / "en"。
    var uiLanguage = "auto"

    var currentBaseURL: String { provider == .openAICompatible ? openAIBaseURL : anthropicBaseURL }
    var currentModel: String { provider == .openAICompatible ? openAIModel : anthropicModel }
    var currentAPIKey: String { provider == .openAICompatible ? openAIAPIKey : anthropicAPIKey }

    func llmConfig() -> LLMConfig {
        LLMConfig(provider: provider, baseURL: currentBaseURL, apiKey: currentAPIKey, model: currentModel)
    }

    enum CodingKeys: String, CodingKey {
        case provider, openAIBaseURL, openAIModel, openAIAPIKey
        case anthropicBaseURL, anthropicModel, anthropicAPIKey
        case refreshInterval, cpuHighlightThreshold, topProcessesToSend, includeProcessPath
        case uiLanguage
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        provider = try c.decodeIfPresent(ProviderKind.self, forKey: .provider) ?? d.provider
        openAIBaseURL = try c.decodeIfPresent(String.self, forKey: .openAIBaseURL) ?? d.openAIBaseURL
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? d.openAIModel
        openAIAPIKey = try c.decodeIfPresent(String.self, forKey: .openAIAPIKey) ?? d.openAIAPIKey
        anthropicBaseURL = try c.decodeIfPresent(String.self, forKey: .anthropicBaseURL) ?? d.anthropicBaseURL
        anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel) ?? d.anthropicModel
        anthropicAPIKey = try c.decodeIfPresent(String.self, forKey: .anthropicAPIKey) ?? d.anthropicAPIKey
        refreshInterval = try c.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? d.refreshInterval
        cpuHighlightThreshold = try c.decodeIfPresent(Double.self, forKey: .cpuHighlightThreshold) ?? d.cpuHighlightThreshold
        topProcessesToSend = try c.decodeIfPresent(Int.self, forKey: .topProcessesToSend) ?? d.topProcessesToSend
        includeProcessPath = try c.decodeIfPresent(Bool.self, forKey: .includeProcessPath) ?? d.includeProcessPath
        uiLanguage = try c.decodeIfPresent(String.self, forKey: .uiLanguage) ?? d.uiLanguage
    }
}

/// 设置持久化：~/Library/Application Support/MacPulse/config.json（0600）。
/// directory 可注入用于测试。
final class SettingsStore: ObservableObject {
    @Published var settings: Settings
    let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        self.fileURL = dir.appendingPathComponent("config.json")
        self.settings = Self.load(from: fileURL) ?? Settings()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacPulse", isDirectory: true)
    }

    @discardableResult
    func save() -> Bool {
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    static func load(from url: URL) -> Settings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }
}
