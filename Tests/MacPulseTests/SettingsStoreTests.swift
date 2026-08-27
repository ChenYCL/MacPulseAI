import XCTest
@testable import MacPulse

final class SettingsStoreTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPulseTests-\(UUID().uuidString)", isDirectory: true)
    }

    func testRoundTripAndPermissions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "初始不应存在配置文件")

        store.settings.provider = .anthropic
        store.settings.anthropicAPIKey = "sk-ant-secret"
        store.settings.topProcessesToSend = 40
        XCTAssertTrue(store.save())

        let reloaded = SettingsStore(directory: dir)
        XCTAssertEqual(reloaded.settings.provider, .anthropic)
        XCTAssertEqual(reloaded.settings.anthropicAPIKey, "sk-ant-secret")
        XCTAssertEqual(reloaded.settings.topProcessesToSend, 40)
        XCTAssertEqual(reloaded.settings.openAIBaseURL, "https://api.openai.com/v1", "未修改字段保持默认值")

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let perms = try XCTUnwrap(attrs[.posixPermissions] as? Int)
        XCTAssertEqual(perms, 0o600, "配置文件权限必须为 0600")
    }

    func testDecodingPartialFileUsesDefaults() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"provider":"anthropic"}"#.utf8).write(to: url)

        let store = SettingsStore(directory: dir)
        XCTAssertEqual(store.settings.provider, .anthropic)
        XCTAssertEqual(store.settings.anthropicBaseURL, "https://api.anthropic.com")
        XCTAssertEqual(store.settings.refreshInterval, 2)
        XCTAssertEqual(store.settings.includeProcessPath, true)
    }

    func testLLMConfigFollowsActiveProvider() {
        var s = Settings()
        s.provider = .openAICompatible
        s.openAIAPIKey = "oai"
        XCTAssertEqual(s.llmConfig().apiKey, "oai")
        XCTAssertEqual(s.llmConfig().baseURL, "https://api.openai.com/v1")
        s.provider = .anthropic
        s.anthropicAPIKey = "ant"
        s.anthropicModel = "claude-x"
        XCTAssertEqual(s.llmConfig().apiKey, "ant")
        XCTAssertEqual(s.llmConfig().model, "claude-x")
        XCTAssertEqual(s.llmConfig().baseURL, "https://api.anthropic.com")
    }
}
