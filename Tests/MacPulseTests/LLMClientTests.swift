import XCTest
@testable import MacPulse

/// AI 对话层测试：Agent 提示词、HITL 动作解析、输出规范化、多轮消息组装。
final class LLMClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        L10n.forced = .zh
    }

    override func tearDown() {
        L10n.forced = nil
        SharedStubURLProtocol.reset()
        super.tearDown()
    }

    private func stubbedSession() -> URLSession { sharedStubbedSession() }

    private func httpResponse(_ url: URL, code: Int) -> HTTPURLResponse { sharedResponse(url, code: code) }

    // MARK: OpenAI 兼容

    func testOpenAISendsBearerAndParsesContent() async throws {
        SharedStubURLProtocol.handler = { req in
            let data = """
            {"choices":[{"index":0,"message":{"role":"assistant","content":"你好，这是分析结果"}}]}
            """.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .openAICompatible, baseURL: "https://api.example.com/v1",
                               apiKey: "sk-test", model: "test-model")
        let service = LLMServiceFactory.service(for: config, session: stubbedSession())

        // 多轮消息直接透传
        let result = try await service.stream(messages: [
            .system("sys"), .user("第一问"), .assistant("第一答"), .user("第二问")
        ], onDelta: { _ in }, onReset: {})

        XCTAssertEqual(result, "你好，这是分析结果")
        let req = try XCTUnwrap(SharedStubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedStubURLProtocol.body(of: req)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertTrue((body["stream"] as? Bool) == true || (body["stream"] as? Int) == nil,
                      "流式标志应存在")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual(messages[3]["role"] as? String, "user")
    }

    func testOpenAICompleteSendsSystemAndUserAndParses() async throws {
        SharedStubURLProtocol.handler = { req in
            let data = #"{"choices":[{"message":{"content":"pong"}}]}"#.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .openAICompatible, baseURL: "https://api.example.com/v1",
                               apiKey: "sk-test", model: "test-model")
        let service = OpenAIService(config: config, session: stubbedSession())
        let result = try await service.complete(system: "sys", user: "usr")
        XCTAssertEqual(result, "pong")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedStubURLProtocol.body(of: XCTUnwrap(SharedStubURLProtocol.lastRequest))) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, 4096, "complete() 是轻量探测，仍用较小预算")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
    }

    func testOpenAIHTTPErrorSurfacesStatusAndBody() async throws {
        SharedStubURLProtocol.handler = { req in
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

    func testAnthropicSendsHeadersExtractsSystemAndParsesTextBlocks() async throws {
        SharedStubURLProtocol.handler = { req in
            let data = """
            {"content":[{"type":"thinking","thinking":"想一想"},{"type":"text","text":"部分一"},{"type":"text","text":"，部分二"}]}
            """.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .anthropic, baseURL: "https://api.anthropic.com",
                               apiKey: "sk-ant-test", model: "claude-sonnet-4-5")
        let service = AnthropicService(config: config, session: stubbedSession())

        let result = try await service.stream(messages: [
            .system("系统提示词"), .user("问题"), .assistant("草稿"), .user("继续")
        ], onDelta: { _ in }, onReset: {})

        XCTAssertEqual(result, "部分一，部分二", "thinking 块不应混入正文")
        let req = try XCTUnwrap(SharedStubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedStubURLProtocol.body(of: req)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-4-5")
        XCTAssertEqual(body["max_tokens"] as? Int, OpenAIService.firstBudget)
        XCTAssertEqual(body["system"] as? String, "系统提示词", "system 消息应抽取到顶层 system 参数")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3, "system 不应出现在 messages 数组中")
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
    }

    func testAnthropicBaseURLWithV1DoesNotDuplicate() async throws {
        SharedStubURLProtocol.handler = { req in
            let data = #"{"content":[{"type":"text","text":"ok"}]}"#.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .anthropic, baseURL: "https://gw.example.com/v1",
                               apiKey: "k", model: "m")
        let service = AnthropicService(config: config, session: stubbedSession())
        _ = try await service.complete(system: "s", user: "u")
        XCTAssertEqual(SharedStubURLProtocol.lastRequest?.url?.absoluteString, "https://gw.example.com/v1/messages")
    }

    func testAnthropicEmptyContentThrows() async throws {
        SharedStubURLProtocol.handler = { req in
            let data = #"{"content":[]}"#.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .anthropic, baseURL: "https://api.anthropic.com", apiKey: "k", model: "m")
        let service = AnthropicService(config: config, session: stubbedSession())
        do {
            _ = try await service.stream(messages: [.user("u")], onDelta: { _ in }, onReset: {})
            XCTFail("应当抛出错误")
        } catch let error as LLMError {
            guard case .emptyResponse = error else { return XCTFail("期望 emptyResponse，实际 \(error)") }
        }
    }

    // MARK: 思考型模型（thinking / reasoning_content）

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var n: Int { lock.lock(); defer { lock.unlock() }; return count }
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    func testAnthropicRetriesWithLargerMaxTokensOnReasoningOnly() async throws {
        let counter = Counter()
        SharedStubURLProtocol.handler = { req in
            switch counter.next() {
            case 1:
                let data = #"{"content":[{"type":"thinking","thinking":"让我想一想…"}],"stop_reason":"max_tokens"}"#.data(using: .utf8)!
                return (self.httpResponse(req.url!, code: 200), data)
            default:
                let data = #"{"content":[{"type":"text","text":"最终分析结果"}],"stop_reason":"end_turn"}"#.data(using: .utf8)!
                return (self.httpResponse(req.url!, code: 200), data)
            }
        }
        let config = LLMConfig(provider: .anthropic, baseURL: "https://api.anthropic.com",
                               apiKey: "k", model: "glm-5.3-flash")
        let service = AnthropicService(config: config, session: stubbedSession())

        let result = try await service.stream(messages: [.user("u")], onDelta: { _ in }, onReset: {})

        XCTAssertEqual(result, "最终分析结果")
        XCTAssertEqual(counter.n, 2, "应在 thinking-only 后自动重试一次")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: SharedStubURLProtocol.body(of: XCTUnwrap(SharedStubURLProtocol.lastRequest))) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, OpenAIService.retryBudget, "重试时 max_tokens 应翻倍")
    }

    /// 回归：吐了正文但被 max_tokens 砍断时，不许当成完整答案交出去。
    ///
    /// 老写法是 `finalize()` 里 `if !text.isEmpty { return text }` 打头，
    /// 于是只要模型吐过一个字，后面的截断判定就永远够不着——半句话的回答被静默当成
    /// 正常结束，既不报错也不重试。界面上的表现就是「说到一半没了」。
    func testTruncatedAfterPartialTextRetriesWithLargerBudget() async throws {
        let counter = Counter()
        SharedStubURLProtocol.handler = { req in
            let n = counter.next()
            let sse: String
            if n == 1 {
                sse = """
                data: {"choices":[{"delta":{"content":"前半句"}}]}

                data: {"choices":[{"delta":{},"finish_reason":"length"}]}

                data: [DONE]

                """
            } else {
                sse = """
                data: {"choices":[{"delta":{"content":"完整的回答"}}]}

                data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

                data: [DONE]

                """
            }
            return (self.httpResponse(req.url!, code: 200), sse.data(using: .utf8)!)
        }
        let config = LLMConfig(provider: .openAICompatible, baseURL: "https://gw.example.com/v1",
                               apiKey: "k", model: "m")
        let service = OpenAIService(config: config, session: stubbedSession())

        var deltas: [String] = []
        var resets = 0
        let result = try await service.stream(messages: [.user("u")],
                                              onDelta: { deltas.append($0) },
                                              onReset: { resets += 1 })

        XCTAssertEqual(counter.n, 2, "截断后必须用加倍预算重试")
        XCTAssertEqual(resets, 1, "重试前必须通知调用方清空已显示的半截回答")
        XCTAssertEqual(result, "完整的回答")
        XCTAssertEqual(deltas, ["前半句", "完整的回答"], "两轮的增量都会发出，靠 onReset 去重")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: SharedStubURLProtocol.body(of: XCTUnwrap(SharedStubURLProtocol.lastRequest))) as? [String: Any])
        XCTAssertEqual(body["max_tokens"] as? Int, OpenAIService.retryBudget)
    }

    /// 加倍预算之后仍然截断：不再抛错把用户已经看到的字删掉，而是留下内容 + 说明。
    func testTruncatedTwiceKeepsPartialAndAppendsNotice() async throws {
        SharedStubURLProtocol.handler = { req in
            let sse = """
            data: {"choices":[{"delta":{"content":"很长的半截"}}]}

            data: {"choices":[{"delta":{},"finish_reason":"length"}]}

            data: [DONE]

            """
            return (self.httpResponse(req.url!, code: 200), sse.data(using: .utf8)!)
        }
        let config = LLMConfig(provider: .openAICompatible, baseURL: "https://gw.example.com/v1",
                               apiKey: "k", model: "m")
        let service = OpenAIService(config: config, session: stubbedSession())

        let result = try await service.stream(messages: [.user("u")], onDelta: { _ in }, onReset: {})
        XCTAssertTrue(result.hasPrefix("很长的半截"), "已经收到的内容必须保留")
        XCTAssertTrue(result.contains("max_tokens"), "必须明确告诉用户这里是被截断的")
    }

    func testAnthropicReasoningOnlyExhaustsRetryThrowsGuidance() async throws {
        let counter = Counter()
        SharedStubURLProtocol.handler = { req in
            _ = counter.next()
            let data = #"{"content":[{"type":"thinking","thinking":"思考内容片段"}],"stop_reason":"max_tokens"}"#.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .anthropic, baseURL: "https://api.anthropic.com", apiKey: "k", model: "m")
        let service = AnthropicService(config: config, session: stubbedSession())

        do {
            _ = try await service.stream(messages: [.user("u")], onDelta: { _ in }, onReset: {})
            XCTFail("应当抛出错误")
        } catch let error as LLMError {
            guard case .reasoningOnly(let preview) = error else { return XCTFail("期望 reasoningOnly，实际 \(error)") }
            XCTAssertTrue(preview.contains("思考内容片段"))
        }
        XCTAssertEqual(counter.n, 2, "重试一次后仍失败才抛出")
    }

    func testOpenAIEmptyContentWithReasoningContentThrowsGuidance() async throws {
        SharedStubURLProtocol.handler = { req in
            let data = """
            {"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"","reasoning_content":"openai 风格推理"}}]}
            """.data(using: .utf8)!
            return (self.httpResponse(req.url!, code: 200), data)
        }
        let config = LLMConfig(provider: .openAICompatible, baseURL: "https://gw.example.com/v1", apiKey: "k", model: "m")
        let service = OpenAIService(config: config, session: stubbedSession())
        L10n.forced = .en
        defer { L10n.forced = nil }
        do {
            _ = try await service.stream(messages: [.user("u")], onDelta: { _ in }, onReset: {})
            XCTFail("应当抛出错误")
        } catch let error as LLMError {
            guard case .reasoningOnly(let preview) = error else { return XCTFail("期望 reasoningOnly，实际 \(error)") }
            XCTAssertTrue(preview.contains("openai"))
            XCTAssertTrue(error.localizedDescription.contains("reasoning"))
        }
    }

    // MARK: HITL 动作解析

    func testAgentActionParsingSingle() {
        let raw = "建议终止该进程。\n<action action=\"quit\" pid=\"32817\"/>"
        let (clean, actions) = AgentActionParser.parse(raw)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.kind, .quit)
        XCTAssertEqual(actions.first?.pid, 32817)
        XCTAssertFalse(clean.contains("<action"))
        XCTAssertTrue(clean.hasPrefix("建议终止该进程"))
    }

    func testAgentActionParsingMultipleAndForceKill() {
        let raw = """
        ## 建议
        <action action="force_kill" pid="100"/>
        另外这个也可以退出：<action action="quit" pid="200" />
        """
        let (_, actions) = AgentActionParser.parse(raw)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].kind, .forceKill)
        XCTAssertEqual(actions[0].pid, 100)
        XCTAssertEqual(actions[1].kind, .quit)
        XCTAssertEqual(actions[1].pid, 200)
    }

    func testAgentActionParsingIgnoresInvalid() {
        let (_, actions) = AgentActionParser.parse(#"<action action="restart" pid="abc"/><action pid="123"/>"#)
        XCTAssertTrue(actions.isEmpty, "未知动作与非法 pid 应被忽略")
    }

    // MARK: Agent Prompt（role 人设 + 主题锁定）

    func testChineseSystemPromptContainsContract() {
        L10n.forced = .zh
        defer { L10n.forced = nil }
        let p = PromptBuilder.systemPrompt()
        XCTAssertTrue(p.contains("Pulse"))
        XCTAssertTrue(p.contains("<action"), "必须包含动作标记协议")
        XCTAssertTrue(p.contains("human-in-the-loop") || p.contains("人工确认"))
        XCTAssertTrue(p.contains("kernel_task"), "必须包含关键进程保护提示")
        XCTAssertTrue(p.contains("超出职责范围") || p.contains("职责"), "必须有主题锁定约束")
    }

    func testEnglishSystemPromptContainsContract() {
        L10n.forced = .en
        defer { L10n.forced = nil }
        let p = PromptBuilder.systemPrompt()
        XCTAssertTrue(p.contains("out of scope"))
        XCTAssertTrue(p.contains("human-in-the-loop"))
        XCTAssertTrue(p.contains("<action"))
    }

    func testAnalysisUserMessageCarriesPayload() throws {
        let load = SystemLoad(userPercent: 32.29, systemPercent: 9.74, idlePercent: 57.96)
        let proc = ProcSample(pid: 1234, name: "node", path: "/usr/local/bin/node", user: "light",
                              uid: 501, isOwnedByMe: true, cpuPercent: 102.2, memPercent: 1.5,
                              rssBytes: 314_572_800, threads: 28, state: "R")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(PromptBuilder.snapshotJSON(load: load, procs: [proc], includePath: true, cores: 8).utf8)) as? [String: Any])
        let sys = try XCTUnwrap(json["system"] as? [String: Any])
        XCTAssertEqual(sys["cores"] as? Int, 8)
        XCTAssertEqual(sys["user_cpu"] as? Double ?? 0, 32.29, accuracy: 0.05)
        let procs = try XCTUnwrap(json["processes"] as? [[String: Any]])
        let p = try XCTUnwrap(procs.first)
        XCTAssertEqual(p["name"] as? String, "node")
        XCTAssertEqual(p["pid"] as? Int, 1234)
        XCTAssertEqual(p["cpu"] as? Double ?? 0, 102.2, accuracy: 0.05)
        XCTAssertEqual(p["threads"] as? Int, 28)
        XCTAssertEqual(p["path"] as? String, "/usr/local/bin/node")

        let msg = PromptBuilder.analysisUserMessage(load: load, procs: [proc],
                                                    includePath: true, cores: 8)
        XCTAssertTrue(msg.contains("1234"))
    }

    func testContextSummaryIsCompact() {
        L10n.forced = .zh
        defer { L10n.forced = nil }
        var procs: [ProcSample] = []
        for i in 0..<20 {
            procs.append(ProcSample(pid: Int32(i + 1), name: "p\(i)", path: "", user: "light",
                                    uid: 501, isOwnedByMe: true, cpuPercent: Double(i),
                                    memPercent: 1, rssBytes: 1024 * 1024, threads: 1, state: "S"))
        }
        let summary = PromptBuilder.contextSummary(load: SystemLoad(), procs: procs, limit: 8)
        XCTAssertEqual(summary.components(separatedBy: "- pid=").count - 1, 8, "只取前 8 条进程")
        XCTAssertTrue(summary.contains("[实时上下文]"))
        XCTAssertTrue(summary.contains("磁盘剩余") || summary.contains("Disk free"), "应包含磁盘信息")
    }

    // MARK: 输出规范化

    func testNormalizedModelOutputStripsMarkdownFence() {
        let wrapped = "```markdown\n## 标题\n- 条目\n```"
        XCTAssertEqual(ChatSession.normalizedModelOutput(wrapped), "## 标题\n- 条目")
        let plainFence = "```\n正文\n```"
        XCTAssertEqual(ChatSession.normalizedModelOutput(plainFence), "正文")
        let inner = "前文\n```bash\nls -la\n```\n后文"
        XCTAssertEqual(ChatSession.normalizedModelOutput(inner), inner)
        XCTAssertEqual(ChatSession.normalizedModelOutput("纯文本"), "纯文本")
    }
}

private extension PromptBuilder {
    /// 从用户消息中提取快照 JSON（首行大括号起）——仅供测试校验载荷字段。
    static func payloadJSON(_ s: String) -> String { s }
}
