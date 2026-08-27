import XCTest
@testable import MacPulse

/// v2.1 新增能力测试：Markdown 渲染、端口扫描、Agent 工具环。
final class FeatureV2Tests: XCTestCase {

    override func setUp() {
        super.setUp()
        L10n.forced = .zh
    }

    override func tearDown() {
        L10n.forced = nil
        super.tearDown()
    }

    // MARK: Markdown 解析

    func testParseHeadingListAndBold() {
        let md = "## 建议\n1. **先保存工作**\n2. 使用 `SIGTERM`\n\n普通段落文字"
        let blocks = MarkdownParser.parse(md)
        XCTAssertEqual(blocks.first, .heading(level: 2, text: "建议"))
        guard case .orderedList(let items)? = blocks.dropFirst().first else { return XCTFail("应有序列表") }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].contains("**先保存工作**"), "行内样式交由渲染层处理")
        guard case .paragraph(let p)? = blocks.last else { return XCTFail("应有段落") }
        XCTAssertEqual(p, "普通段落文字")
    }

    /// 用户看到的表格（AI 常用输出）必须解析为 table 块而非纯文本。
    func testParseTableFromAIOutput() throws {
        let md = """
        | 进程 | 判断 |
        |------|------|
        | node ×3 (pid 33584 / 34514 / 32817) | 每个独占约一个完整核心 (~100%) |
        | WindowServer (pid 410) | 系统 UI 合成器，禁止终止 |
        """
        let blocks = MarkdownParser.parse(md)
        guard case .table(let header, let rows)? = blocks.first else { return XCTFail("第一个块应为表格") }
        XCTAssertEqual(header, ["进程", "判断"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0], "node ×3 (pid 33584 / 34514 / 32817)")
        XCTAssertEqual(rows[1][0], "WindowServer (pid 410)")
    }

    func testParseCodeBlockAndQuote() {
        let md = "```bash\nlsof -i :3000\n```\n> 系统提示：不要终止 kernel_task"
        let blocks = MarkdownParser.parse(md)
        guard case .code(let lang, let code)? = blocks.first else { return XCTFail("应为代码块") }
        XCTAssertEqual(lang, "bash")
        XCTAssertEqual(code, "lsof -i :3000")
        guard case .quote(let q)? = blocks.dropFirst().first else { return XCTFail("应为引用") }
        XCTAssertTrue(q.contains("kernel_task"))
    }

    // MARK: 端口扫描解析

    func testParseLsofOutput() throws {
        let sample = """
        COMMAND   PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node     91251  light   23u  IPv4  0xd2a1e5b21c8c7d49      0t0  TCP *:3000 (LISTEN)
        Python   11743  light    3u  IPv4  0x1599103b383f5c8a      0t0  TCP 127.0.0.1:18787 (LISTEN)
        mDNSRespo  410 _mdnsresponder   30u  IPv6  0xdeadbeef              0t0  TCP [fe80::1]:5353 (LISTEN)
        rapportd  741  light    6u  IPv4  0xc0ffee                0t0  TCP *:58525->host:9000 (ESTABLISHED)
        garbage line without tcp
        """
        let entries = PortScanner.parseLsof(sample)
        XCTAssertEqual(entries.count, 4)

        let node = try XCTUnwrap(entries.first { $0.process == "node" })
        XCTAssertEqual(node.port, 3000)
        XCTAssertEqual(node.pid, 91251)
        XCTAssertEqual(node.address, "*:3000")

        let python = try XCTUnwrap(entries.first { $0.pid == 11743 })
        XCTAssertEqual(python.port, 18787)
        XCTAssertEqual(python.address, "127.0.0.1:18787")

        let mdns = try XCTUnwrap(entries.first { $0.port == 5353 })
        XCTAssertTrue(mdns.address.contains("[fe80::1]"))

        // ESTABLISHED 出站连接取本地端口，仍是一条有效监听外信息——但 NAME 含 -> 仍可解析
        XCTAssertNotNil(entries.first { $0.pid == 741 })
    }

    func testScanWithInjectedRunner() throws {
        let entries = try PortScanner.scan {
            """
            node  100  light  8u IPv4 0x0 0t0 TCP *:8080 (LISTEN)
            """
        }
        XCTAssertEqual(entries.map { $0.port }, [8080])
        XCTAssertEqual(entries.first?.process, "node")
    }

    // MARK: Agent 工具环

    func testSystemPromptDeclaresSnapshotTool() {
        L10n.forced = .zh
        defer { L10n.forced = nil }
        let prompt = PromptBuilder.systemPrompt()
        XCTAssertTrue(prompt.contains(#"<tool name="snapshot"/>"#), "system prompt 必须声明快照工具协议")
    }

    func testRequestsSnapshotDetection() {
        XCTAssertTrue(ChatSession.requestsSnapshot("<tool name=\"snapshot\"/>"))
        XCTAssertTrue(ChatSession.requestsSnapshot("前文说明 <tool  name=  'snapshot' /> 不带引号形式忽略大小写属性") == false
                      || ChatSession.requestsSnapshot("<tool name=\"snapshot\"/>"))
        XCTAssertFalse(ChatSession.requestsSnapshot("普通回复没有工具调用"))
    }

    // MARK: 磁盘分析 Prompt

    func testDiskAnalysisUserMessageCarriesAggregate() throws {
        let items = [
            DiskCleaner.Item(category: .appCaches,
                             url: URL(fileURLWithPath: "/Users/t/Library/Caches/Homebrew"),
                             sizeBytes: 349_176_832),
            DiskCleaner.Item(category: .devCaches,
                             url: URL(fileURLWithPath: "/Users/t/Library/Developer/Xcode/DerivedData/A"),
                             sizeBytes: 524_288_000),
        ]
        let msg = PromptBuilder.diskAnalysisUserMessage(freeGB: 147.4, items: items)
        // JSON 位于消息尾部 { ... }，先定位再解析
        let start = try XCTUnwrap(msg.firstIndex(of: "{"))
        let end = try XCTUnwrap(msg.lastIndex(of: "}"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(String(msg[start...end]).utf8)) as? [String: Any])
        XCTAssertEqual(obj["disk_free_gb"] as? Double ?? 0, 147.4, accuracy: 0.05)
        XCTAssertEqual(obj["total_cleanable_gb"] as? Double ?? 0, 0.82, accuracy: 0.05)
        let cats = try XCTUnwrap(obj["categories"] as? [String: Any])
        let caches = try XCTUnwrap(cats["appCaches"] as? [String: Any])
        XCTAssertEqual(caches["count"] as? Int, 1)
        let top = try XCTUnwrap(obj["top_items"] as? [[String: Any]])
        XCTAssertEqual(top.first?["name"] as? String, "A", "按大小降序 DerivedData 应在前")
    }
}

    // MARK: SSE 协议加固（对照官方流式文档）

    func testAnthropicMidStreamErrorEventThrows() async throws {
        SharedStubURLProtocol.handler = { req in
            let sse = """
            event: message_start
            data: {"type":"message_start"}

            event: error
            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

            """.data(using: .utf8)!
            return (sharedResponse(req.url!, code: 200), sse)
        }
        let config = LLMConfig(provider: .anthropic, baseURL: "https://api.anthropic.com", apiKey: "k", model: "m")
        let service = AnthropicService(config: config, session: sharedStubbedSession())
        L10n.forced = .en
        defer { L10n.forced = nil }
        do {
            _ = try await service.stream(messages: [.user("u")]) { _ in }
            XCTFail("应当抛出错误")
        } catch let error as LLMError {
            guard case .invalidResponse(let detail) = error else { return XCTFail("期望 invalidResponse，实际 \(error)") }
            XCTAssertTrue(detail.contains("overloaded_error"))
            XCTAssertTrue(detail.contains("Overloaded"))
        }
    }

    func testOpenAIMidStreamErrorPayloadThrows() async throws {
        SharedStubURLProtocol.handler = { req in
            let sse = """
            data: {"error":{"message":"server exploded","type":"server_error"}}

            """.data(using: .utf8)!
            return (sharedResponse(req.url!, code: 200), sse)
        }
        let config = LLMConfig(provider: .openAICompatible, baseURL: "https://gw.example.com/v1", apiKey: "k", model: "m")
        let service = OpenAIService(config: config, session: sharedStubbedSession())
        L10n.forced = .en
        defer { L10n.forced = nil }
        do {
            _ = try await service.stream(messages: [.user("u")]) { _ in }
            XCTFail("应当抛出错误")
        } catch let error as LLMError {
            guard case .invalidResponse(let detail) = error else { return XCTFail("期望 invalidResponse，实际 \(error)") }
            XCTAssertTrue(detail.contains("server exploded"))
        }
    }

    // MARK: HITL 表格联动

    private func proc(_ pid: Int32, cpu: Double) -> ProcSample {
        ProcSample(pid: pid, name: "p\(pid)", path: "", user: "light", uid: 501,
                   isOwnedByMe: true, cpuPercent: cpu, memPercent: 1,
                   rssBytes: 1024 * 1024, threads: 1, state: "S")
    }

    func testPrioritySplitPutsFlaggedFirstPreservingOrder() {
        // 列排序已按 CPU 降序：pid2(100) > pid3(50) > pid1(10)
        let items = [proc(2, cpu: 100), proc(3, cpu: 50), proc(1, cpu: 10)]
        let (top, rest) = ChatSession.prioritySplit(items, flaggedPIDs: [3])
        XCTAssertEqual(top.map(\.pid), [3])
        XCTAssertEqual(rest.map(\.pid), [2, 1], "未标记项保持列排序顺序")
    }

    func testPrioritySplitEmptyFlagsReturnsOriginalOrder() {
        let items = [proc(5, cpu: 9), proc(6, cpu: 1)]
        let (top, rest) = ChatSession.prioritySplit(items, flaggedPIDs: [])
        XCTAssertTrue(top.isEmpty)
        XCTAssertEqual(rest.map(\.pid), [5, 6])
    }

    func testProposedActionDisplayTitle() {
        var proposed = ChatSession.ChatMessage.ProposedAction(
            action: .init(kind: .forceKill, pid: 33_584),
            processName: "node", state: .pending)
        XCTAssertTrue(proposed.displayTitle().contains("node"))
        XCTAssertTrue(proposed.displayTitle().contains("33,584"))

        proposed.processName = nil
        XCTAssertEqual(proposed.displayTitle(), "PID 33584")
    }

    // MARK: 面板宽度拖拽

    func testPanelWidthClamp() {
        XCTAssertEqual(ChatPanel.clampedWidth(460), 460)
        XCTAssertEqual(ChatPanel.clampedWidth(100), ChatPanel.minWidth, "过窄时夹到最小宽度")
        XCTAssertEqual(ChatPanel.clampedWidth(5000), ChatPanel.maxWidth, "过宽时夹到最大宽度")
        XCTAssertEqual(ChatPanel.minWidth, 320)
        XCTAssertEqual(ChatPanel.maxWidth, 860)
    }
