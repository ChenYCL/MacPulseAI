import XCTest
@testable import MacPulse

final class LLMClientTests: XCTestCase {

    /// URLProtocol 桩：拦截 URLSession 请求，可捕获请求并返回预设响应。
    final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            do {
                let (resp, data) = try handler(request)
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        static func body(of request: URLRequest) -> Data {
            if let d = request.httpBody { return d }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 16_384
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: bufSize)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            return data
        }

        static func reset() { handler = nil; lastRequest = nil }
    }

    private func stubbedSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override func setUp() {
        super.setUp()
        L10n.forced = .zh
    }

    override func tearDown() {
        L10n.forced = nil
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func httpResponse(_ url: URL, code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    // MARK: OpenAI

    func testOpenAISendsBearerAndParsesContent() async throws {
        StubURLProtocol.handler = { req in
            let data = """
            {"choices":[{"index":0,"message":{"role":"assistant","content":"你好，这是分析结果"}}]}
            """.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .openAICompatible, baseURL: "https://api.example.com/v1",
                               apiKey: "sk-test", model: "test-model")
        let service = LLMServiceFactory.service(for: config, session: stubbedSession())

        let result = try await service.complete(system: "sys", user: "usr")

        XCTAssertEqual(result, "你好，这是分析结果")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: req)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "test-model")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
    }

    func testOpenAIHTTPErrorSurfacesStatusAndBody() async throws {
        StubURLProtocol.handler = { req in
            let data = #"{"error":{"message":"Incorrect API key"}}"#.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 401), data)
        }
        let config = LLMConfig(provider: .openAICompatible, baseURL: "https://api.example.com/v1",
                               apiKey: "bad", model: "m")
        let service = LLMServiceFactory.service(for: config, session: stubbedSession())

        do {
            _ = try await service.complete(system: "s", user: "u")
            XCTFail("应当抛出错误")
        } catch let error as LLMError {
            guard case .http(let code, let body) = error else { return XCTFail("期望 http 错误，实际 \(error)") }
            XCTAssertEqual(code, 401)
            XCTAssertTrue(body.contains("Incorrect API key"))
        }
    }

    // MARK: Anthropic

    func testAnthropicSendsHeadersAndParsesTextBlocks() async throws {
        StubURLProtocol.handler = { req in
            let data = """
            {"id":"msg_1","content":[{"type":"text","text":"部分一"},{"type":"text","text":"，部分二"}]}
            """.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .anthropic, baseURL: "https://api.anthropic.com",
                               apiKey: "sk-ant-test", model: "claude-sonnet-4-5")
        let service = AnthropicService(config: config, session: stubbedSession())

        let result = try await service.complete(system: "sys", user: "usr")

        XCTAssertEqual(result, "部分一，部分二")
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: req)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 1024)
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.first?["role"] as? String, "user")
    }

    func testAnthropicBaseURLWithV1DoesNotDuplicate() async throws {
        StubURLProtocol.handler = { req in
            let data = #"{"content":[{"type":"text","text":"ok"}]}"#.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .anthropic, baseURL: "https://gw.example.com/v1",
                               apiKey: "k", model: "m")
        let service = AnthropicService(config: config, session: stubbedSession())
        _ = try await service.complete(system: "s", user: "u")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.absoluteString, "https://gw.example.com/v1/messages")
    }

    func testAnthropicEmptyContentThrows() async throws {
        StubURLProtocol.handler = { req in
            let data = #"{"content":[]}"#.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .anthropic, baseURL: "https://api.anthropic.com", apiKey: "k", model: "m")
        let service = AnthropicService(config: config, session: stubbedSession())
        do {
            _ = try await service.complete(system: "s", user: "u")
            XCTFail("应当抛出错误")
        } catch let error as LLMError {
            guard case .emptyResponse = error else { return XCTFail("期望 emptyResponse，实际 \(error)") }
        }
    }

    // MARK: Prompt 构建

    private func sampleProc() -> ProcSample {
        ProcSample(pid: 1234, name: "node", path: "/usr/local/bin/node", user: "light",
                   uid: 501, isOwnedByMe: true, cpuPercent: 102.2, memPercent: 1.5,
                   rssBytes: 314_572_800, threads: 28, state: "R")
    }

    func testAnalysisPromptIncludesFields() throws {
        let load = SystemLoad(userPercent: 32.29, systemPercent: 9.74, idlePercent: 57.96)
        let prompt = PromptBuilder.analysisPrompt(load: load, procs: [sampleProc()], includePath: true, cores: 8)
        XCTAssertTrue(prompt.system.contains("总体判断"))
        XCTAssertTrue(prompt.system.contains("建议"))

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PromptBuilder.analysisPayloadJSON(load: load, procs: [sampleProc()], includePath: true, cores: 8).utf8)) as? [String: Any])
        let sys = try XCTUnwrap(obj["system"] as? [String: Any])
        XCTAssertEqual(sys["cores"] as? Int, 8)
        XCTAssertEqual(sys["user_cpu"] as? Double ?? 0, 32.29, accuracy: 0.05)
        let procs = try XCTUnwrap(obj["processes"] as? [[String: Any]])
        XCTAssertEqual(procs.count, 1)
        let p = try XCTUnwrap(procs.first)
        XCTAssertEqual(p["name"] as? String, "node")
        XCTAssertEqual(p["pid"] as? Int, 1234)
        XCTAssertEqual(p["cpu"] as? Double ?? 0, 102.2, accuracy: 0.05)
        XCTAssertEqual(p["threads"] as? Int, 28)
        XCTAssertEqual(p["user"] as? String, "light")
        XCTAssertEqual(p["path"] as? String, "/usr/local/bin/node")
    }

    func testAnalysisPromptExcludesPathWhenDisabled() throws {
        let prompt = PromptBuilder.analysisPrompt(load: SystemLoad(), procs: [sampleProc()],
                                                  includePath: false, cores: 8)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PromptBuilder.analysisPayloadJSON(load: SystemLoad(), procs: [sampleProc()], includePath: false, cores: 8).utf8)) as? [String: Any])
        let procs = try XCTUnwrap(obj["processes"] as? [[String: Any]])
        XCTAssertNil(procs.first?["path"])
        XCTAssertEqual(procs.first?["name"] as? String, "node")
    }

    func testExplainPromptMentionsRiskLevels() {
        let prompt = PromptBuilder.explainPrompt(proc: sampleProc(), load: SystemLoad(),
                                                 includePath: true, cores: 8)
        XCTAssertTrue(prompt.system.contains("🟢"))
        XCTAssertTrue(prompt.user.contains("node"))
    }

    // MARK: 多语言 Prompt

    func testEnglishAnalysisPrompt() {
        L10n.forced = .en
        defer { L10n.forced = .zh }
        let prompt = PromptBuilder.analysisPrompt(load: SystemLoad(), procs: [sampleProc()],
                                                  includePath: true, cores: 8)
        XCTAssertTrue(prompt.system.contains("## Overall Assessment"))
        XCTAssertTrue(prompt.system.contains("## Recommendations"))
        XCTAssertTrue(prompt.system.contains("🔴"))
        XCTAssertTrue(prompt.user.contains("\"node\""))
    }

    func testEnglishExplainPrompt() {
        L10n.forced = .en
        defer { L10n.forced = .zh }
        let prompt = PromptBuilder.explainPrompt(proc: sampleProc(), load: SystemLoad(),
                                                 includePath: true, cores: 8)
        XCTAssertTrue(prompt.system.contains("safe to terminate"))
        XCTAssertTrue(prompt.system.contains("🟢"))
    }

    func testLanguageOverrideAutoDetects() {
        L10n.forced = nil
        L10n.overrideCode = "en"
        XCTAssertEqual(L10n.current, .en)
        L10n.overrideCode = "zh"
        XCTAssertEqual(L10n.current, .zh)
        L10n.overrideCode = "auto"
        XCTAssertEqual(L10n.current, L10n.Lang.detect())
        L10n.overrideCode = nil
    }
}
