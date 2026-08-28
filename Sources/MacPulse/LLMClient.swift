import Foundation

// MARK: - 配置

struct LLMConfig {
    var provider: Settings.ProviderKind
    var baseURL: String
    var apiKey: String
    var model: String
}

// MARK: - 错误

enum LLMError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case emptyResponse
    /// 已经吐了正文但被 max_tokens 截断在半截。带上已收到的部分，供重试或降级展示。
    case truncated(String)
    /// 模型只返回了思考过程没有正文（常见于思考型模型 + max_tokens 过小被截断）。
    case reasoningOnly(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u):
            return L10n.s("Base URL 无效：\(u)", "Invalid Base URL: \(u)")
        case .http(let code, let body):
            let preview = String(body.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty
                ? L10n.s("HTTP \(code)", "HTTP \(code)")
                : L10n.s("HTTP \(code)：\(preview)", "HTTP \(code): \(preview)")
        case .emptyResponse:
            return L10n.s("模型返回内容为空", "Model returned empty content")
        case .truncated:
            return L10n.s("回答被 max_tokens 截断", "Reply was cut off by max_tokens")
        case .reasoningOnly(let preview):
            let trimmed = String(preview.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            return L10n.s("模型只输出了思考过程，未生成正文（常见于思考型模型的 max_tokens 被截断）。可在设置中换用其他模型。\n思考片段：\(trimmed)",
                          "The model only produced reasoning with no final answer (thinking model truncated by max_tokens?). Try a different model in Settings.\nReasoning excerpt: \(trimmed)")
        case .invalidResponse(let detail):
            let preview = String(detail.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            return L10n.s("响应解析失败：\(preview)", "Failed to parse response: \(preview)")
        }
    }
}

// MARK: - 消息与服务协议

/// 一条对话消息；role 直接对应两家协议。
struct LLMMessage: Equatable {
    enum Role: String {
        case system, user, assistant
    }
    let role: Role
    let content: String

    static func system(_ content: String) -> LLMMessage { .init(role: .system, content: content) }
    static func user(_ content: String) -> LLMMessage { .init(role: .user, content: content) }
    static func assistant(_ content: String) -> LLMMessage { .init(role: .assistant, content: content) }
}

protocol LLMServicing {
    /// 非流式补全（一次性返回）。适合轻量探测（如「测试连接」）；内部同样带 max_tokens 重试。
    func complete(system: String, user: String) async throws -> String

    /// 多轮流式补全：增量通过 onDelta 回调，最终返回拼接后的完整文本。
    /// max_tokens 截断时自动加倍重试一次；重试前会先调 onReset，
    /// 让调用方把已经显示出去的半截回答清掉——否则第二轮的增量会接在第一轮后面变成重复。
    /// Anthropic 协议会把 role==system 的消息抽出为顶层 system 参数。
    func stream(messages: [LLMMessage],
                onDelta: @escaping (String) -> Void,
                onReset: @escaping () -> Void) async throws -> String
}

enum LLMServiceFactory {
    static func service(for config: LLMConfig, session: URLSession = .shared) -> LLMServicing {
        switch config.provider {
        case .openAICompatible: return OpenAIService(config: config, session: session)
        case .anthropic: return AnthropicService(config: config, session: session)
        }
    }
}

private func normalizedBase(_ raw: String) throws -> String {
    var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    guard !base.isEmpty, URL(string: base) != nil else { throw LLMError.badURL(raw) }
    return base
}

// MARK: - OpenAI 兼容

struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let temperature: Double
    let max_tokens: Int
    let stream: Bool
    let messages: [Message]

    init(model: String, temperature: Double, maxTokens: Int, stream: Bool, messages: [Message]) {
        self.model = model
        self.temperature = temperature
        self.max_tokens = maxTokens
        self.stream = stream
        self.messages = messages
    }
}

struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            /// 思考型模型的推理内容（部分 OpenAI 兼容网关会单独返回此字段）。
            let reasoning_content: String?
            private enum CodingKeys: String, CodingKey { case content, reasoning_content }
        }
        let finish_reason: String?
        let message: Message
    }
    let choices: [Choice]
}

final class OpenAIService: LLMServicing {
    let config: LLMConfig
    let session: URLSession

    init(config: LLMConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// 测试连接等轻量场景的非流式补全。
    func complete(system: String, user: String) async throws -> String {
        do {
            return try await sendOnce(maxTokens: 4096,
                                      messages: [.system(system), .user(user)])
        } catch LLMError.reasoningOnly {
            return try await sendOnce(maxTokens: 8192,
                                      messages: [.system(system), .user(user)])
        }
    }

    func stream(messages: [LLMMessage],
                onDelta: @escaping (String) -> Void,
                onReset: @escaping () -> Void) async throws -> String {
        do {
            return try await streamOnce(maxTokens: Self.firstBudget, messages: messages, onDelta: onDelta)
        } catch LLMError.reasoningOnly {
            onReset()
            return try await streamOnce(maxTokens: Self.retryBudget, messages: messages,
                                        onDelta: onDelta, tolerateTruncation: true)
        } catch LLMError.truncated {
            // 半截回答已经显示出去了，重试前必须先让调用方清掉，否则会接成两遍。
            onReset()
            return try await streamOnce(maxTokens: Self.retryBudget, messages: messages,
                                        onDelta: onDelta, tolerateTruncation: true)
        }
    }

    /// 这些报告动辄带表格，4096 太紧，正常回答也会被砍。
    static let firstBudget = 8192
    static let retryBudget = 16384

    private func makeRequest(maxTokens: Int, stream: Bool, messages: [LLMMessage]) throws -> URLRequest {
        let base = try normalizedBase(config.baseURL)
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.badURL(config.baseURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // 非流式（设置里的「测试连接」、短问答）也可能落在慢网关/推理模型上，给到 5 分钟。
        req.timeoutInterval = stream ? 600 : 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(model: config.model,
                              temperature: 0.3,
                              maxTokens: maxTokens,
                              stream: stream,
                              messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) })
        )
        return req
    }

    private func sendOnce(maxTokens: Int, messages: [LLMMessage]) async throws -> String {
        let req = try makeRequest(maxTokens: maxTokens, stream: false, messages: messages)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.invalidResponse("非 HTTP 响应") }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            guard let choice = decoded.choices.first else { throw LLMError.emptyResponse }
            if let content = choice.message.content, !content.isEmpty { return content }
            if let reasoning = choice.message.reasoning_content, !reasoning.isEmpty {
                throw LLMError.reasoningOnly(reasoning)
            }
            if choice.finish_reason == "length" {
                throw LLMError.reasoningOnly(L10n.s("（响应因 max_tokens 截断）", "(response truncated by max_tokens)"))
            }
            throw LLMError.emptyResponse
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.invalidResponse(String(data: data, encoding: .utf8) ?? "\(error)")
        }
    }

    private func streamOnce(maxTokens: Int, messages: [LLMMessage],
                            onDelta: @escaping (String) -> Void,
                            tolerateTruncation: Bool = false) async throws -> String {
        let req = try makeRequest(maxTokens: maxTokens, stream: true, messages: messages)
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw LLMError.http(http.statusCode, body)
        }

        var acc = SSEAccumulator()
        acc.onDelta = onDelta
        var sawData = false
        var nonSSEBuffer = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data:") {
                sawData = true
                try acc.absorbOpenAIChunk(jsonData: String(line.dropFirst(5)))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                nonSSEBuffer += line
            }
        }
        // 网关不支持流式时回落为普通 JSON 解析
        if !sawData {
            if let data = nonSSEBuffer.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(OpenAIChatResponse.self, from: data) {
                if let content = decoded.choices.first?.message.content, !content.isEmpty { return content }
                if let reasoning = decoded.choices.first?.message.reasoning_content, !reasoning.isEmpty {
                    throw LLMError.reasoningOnly(reasoning)
                }
            }
        }
        return try acc.finalize(tolerateTruncation: tolerateTruncation)
    }
}

// MARK: - Anthropic

struct AnthropicRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let max_tokens: Int
    let stream: Bool
    let system: String?
    let messages: [Message]

    init(model: String, maxTokens: Int, stream: Bool, system: String?, messages: [Message]) {
        self.model = model
        self.max_tokens = maxTokens
        self.stream = stream
        self.system = system
        self.messages = messages
    }
}

struct AnthropicResponse: Decodable {
    struct Block: Decodable {
        let type: String?
        let text: String?
        /// 思考型模型（如 GLM/claude 扩展思考）可能单独输出 thinking 块。
        let thinking: String?
        private enum CodingKeys: String, CodingKey { case type, text, thinking }
    }
    let content: [Block]
    let stop_reason: String?
}

final class AnthropicService: LLMServicing {
    let config: LLMConfig
    let session: URLSession

    init(config: LLMConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private func messagesURL() throws -> URL {
        let base = try normalizedBase(config.baseURL)
        let path = base.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        guard let url = URL(string: base + path) else { throw LLMError.badURL(config.baseURL) }
        return url
    }

    /// 测试连接等轻量场景的非流式补全。
    func complete(system: String, user: String) async throws -> String {
        do {
            return try await sendOnce(maxTokens: 4096, system: system,
                                      messages: [.user(user)])
        } catch LLMError.reasoningOnly {
            return try await sendOnce(maxTokens: 8192, system: system,
                                      messages: [.user(user)])
        }
    }

    func stream(messages: [LLMMessage],
                onDelta: @escaping (String) -> Void,
                onReset: @escaping () -> Void) async throws -> String {
        // role==system 的消息抽取为 Anthropic 顶层 system 参数
        let system = messages.filter { $0.role == .system }.map { $0.content }.joined(separator: "\n\n")
        let chat = messages.filter { $0.role != .system }
        do {
            return try await streamOnce(maxTokens: OpenAIService.firstBudget,
                                        system: system, chat: chat, onDelta: onDelta)
        } catch LLMError.reasoningOnly {
            onReset()
            return try await streamOnce(maxTokens: OpenAIService.retryBudget, system: system,
                                        chat: chat, onDelta: onDelta, tolerateTruncation: true)
        } catch LLMError.truncated {
            // 半截回答已经显示出去了，重试前必须先让调用方清掉，否则会接成两遍。
            onReset()
            return try await streamOnce(maxTokens: OpenAIService.retryBudget, system: system,
                                        chat: chat, onDelta: onDelta, tolerateTruncation: true)
        }
    }

    private func makeRequest(maxTokens: Int, stream: Bool, system: String?, chat: [LLMMessage]) throws -> URLRequest {
        let url = try messagesURL()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // 非流式（设置里的「测试连接」、短问答）也可能落在慢网关/推理模型上，给到 5 分钟。
        req.timeoutInterval = stream ? 600 : 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !config.apiKey.isEmpty {
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.httpBody = try JSONEncoder().encode(
            AnthropicRequest(model: config.model,
                             maxTokens: maxTokens,
                             stream: stream,
                             system: system?.isEmpty == true ? nil : system,
                             messages: chat.map { .init(role: $0.role.rawValue, content: $0.content) })
        )
        return req
    }

    private func sendOnce(maxTokens: Int, system: String, messages: [LLMMessage]) async throws -> String {
        let req = try makeRequest(maxTokens: maxTokens, stream: false, system: system, chat: messages)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.invalidResponse("非 HTTP 响应") }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            let text = decoded.content.filter { $0.type == nil || $0.type == "text" }
                .compactMap { $0.text }.joined()
            if !text.isEmpty { return text }

            let reasoning = decoded.content.compactMap { $0.thinking }.joined()
            if !reasoning.isEmpty { throw LLMError.reasoningOnly(reasoning) }
            if decoded.stop_reason == "max_tokens" {
                throw LLMError.reasoningOnly(L10n.s("（响应因 max_tokens 截断）", "(response truncated by max_tokens)"))
            }
            throw LLMError.emptyResponse
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.invalidResponse(String(data: data, encoding: .utf8) ?? "\(error)")
        }
    }

    private func streamOnce(maxTokens: Int, system: String, chat: [LLMMessage],
                            onDelta: @escaping (String) -> Void,
                            tolerateTruncation: Bool = false) async throws -> String {
        let req = try makeRequest(maxTokens: maxTokens, stream: true, system: system, chat: chat)
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw LLMError.http(http.statusCode, body)
        }

        var acc = SSEAccumulator()
        acc.onDelta = onDelta
        var sawEvent = false
        var nonSSEBuffer = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data:") {
                sawEvent = true
                try acc.absorbAnthropicEvent(jsonPayload: String(line.dropFirst(5)))
            } else if !line.hasPrefix("event:"), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                nonSSEBuffer += line
            }
        }
        // 网关不支持流式时回落为普通 JSON 解析
        if !sawEvent {
            if let data = nonSSEBuffer.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: data) {
                let text = decoded.content.filter { $0.type == nil || $0.type == "text" }
                    .compactMap { $0.text }.joined()
                if !text.isEmpty { return text }
                let reasoning = decoded.content.compactMap { $0.thinking }.joined()
                if !reasoning.isEmpty { throw LLMError.reasoningOnly(reasoning) }
            }
        }
        return try acc.finalize(tolerateTruncation: tolerateTruncation)
    }
}

// MARK: - SSE 流式解析（纯函数，便于单测）

/// 流式会话的累计状态与判定逻辑。
struct SSEAccumulator {
    var text = ""
    var reasoning = ""
    var stopReason: String?
    /// 流中段的显式错误事件（Anthropic `error` event / OpenAI 兼容 `data:{"error":...}`）。
    var streamError: String?
    var onDelta: ((String) -> Void)?

    mutating func absorbOpenAIChunk(jsonData: String) throws {
        let trimmed = jsonData.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "[DONE]" else { return }
        guard let data = trimmed.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else { return }
        // 兼容网关在流中报告错误（无 choices 仅 error 对象）
        if let errBody = chunk.error?.error?.message ?? chunk.error?.message {
            streamError = streamError ?? errBody
            return
        }
        guard let choice = chunk.choices?.first else { return }
        if let d = choice.delta?.content, !d.isEmpty {
            text += d
            onDelta?(d)
        }
        if let r = choice.delta?.reasoning_content, !r.isEmpty { reasoning += r }
        if let f = choice.finish_reason { stopReason = f }
    }

    mutating func absorbAnthropicEvent(jsonPayload: String) throws {
        guard let data = jsonPayload.trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data) else { return }
        switch event.type {
        case "content_block_delta":
            if let t = event.delta?.text, !t.isEmpty {
                text += t
                onDelta?(t)
            }
            if let th = event.delta?.thinking, !th.isEmpty { reasoning += th }
        case "message_delta":
            if let sr = event.delta?.stop_reason { stopReason = sr }
        case "error":
            // 官方协议：流中失败以独立 error 事件呈现（如 overloaded_error），而非 HTTP 状态码
            if let msg = event.error?.message {
                streamError = (streamError ?? "") + "[\(event.error?.type ?? "error")] \(msg)"
            } else {
                streamError = streamError ?? "unknown stream error"
            }
        default:
            // ping / message_start / *_block_stop 等事件按协议忽略即可
            break
        }
    }

    /// 结束时判定正文；思考-only/截断/流中错误等情况抛出可操作的错误。
    ///
    /// 顺序很重要：**必须先看 stopReason 再看有没有正文**。
    /// 早先的写法是 `if !text.isEmpty { return text }` 打头，于是只要模型吐过一个字，
    /// 后面的截断判定和流中错误判定就永远够不着——一段被 max_tokens 砍在半句的回答
    /// 会被当成完整答案交出去，既不报错也不重试，界面上就是「说到一半没了」。
    ///
    /// - Parameter tolerateTruncation: 已经是加倍预算的第二轮了，再截断也不抛错，
    ///   而是把半截内容连同说明一起交出去——总比把用户已经看到的字删掉强。
    func finalize(tolerateTruncation: Bool = false) throws -> String {
        let cut = (stopReason == "max_tokens" || stopReason == "length")

        if !text.isEmpty {
            if cut {
                if tolerateTruncation { return text + Self.truncationNotice }
                throw LLMError.truncated(text)
            }
            // 吐了正文但网关中途报错：内容留给用户，同时把错误说清楚，不要假装正常结束。
            if let errText = streamError {
                return text + Self.streamErrorNotice(errText)
            }
            return text
        }

        if let errText = streamError { throw LLMError.invalidResponse(errText) }
        if !reasoning.isEmpty { throw LLMError.reasoningOnly(reasoning) }
        if cut {
            throw LLMError.reasoningOnly(L10n.s("（响应因 max_tokens 截断）", "(response truncated by max_tokens)"))
        }
        throw LLMError.emptyResponse
    }

    static let truncationNotice = L10n.s(
        "\n\n> ⚠️ 回答在这里被 max_tokens 截断了（已按加倍预算重试过一次）。可以让我「接着上面继续」。",
        "\n\n> ⚠️ The reply was cut off here by max_tokens (already retried with double the budget). Ask me to continue from where it stopped.")

    static func streamErrorNotice(_ detail: String) -> String {
        let preview = String(detail.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        return L10n.s("\n\n> ⚠️ 输出中途被服务端打断：\(preview)",
                      "\n\n> ⚠️ The stream was interrupted by the server: \(preview)")
    }
}

/// Anthropic 流事件结构。
struct AnthropicStreamEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let stop_reason: String?
    }
    struct ErrorBody: Decodable {
        let type: String?
        let message: String?
    }
    let type: String?
    let delta: Delta?
    let error: ErrorBody?
}

/// OpenAI 流块结构。
struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoning_content: String?
        }
        let finish_reason: String?
        let delta: Delta?
    }
    struct ErrorPayload: Decodable {
        struct Body: Decodable { let message: String?; let type: String? }
        let message: String?
        let type: String?
        let error: Body?

        var bestMessage: String? { error?.message ?? message }
        var bestType: String? { error?.type ?? type }
    }
    let choices: [Choice]?
    let error: ErrorPayload?
}

// MARK: - Prompt 构建（Agent 角色，主题锁定）

enum PromptBuilder {
    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private static func processJSON(_ p: ProcSample, includePath: Bool) -> [String: Any] {
        var d: [String: Any] = [
            "name": p.name,
            "pid": Int(p.pid),
            "cpu": round1(p.cpuPercent),
            "mem_percent": round1(p.memPercent),
            "rss_mb": (Double(p.rssBytes) / 1_048_576 * 10).rounded() / 10,
            "threads": p.threads,
            "user": p.user,
            "state": p.state
        ]
        if includePath, !p.path.isEmpty { d["path"] = p.path }
        return d
    }

    private static func payloadJSON(_ payload: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Agent 人设 + 主题锁定 + HITL 动作协议。
    static func systemPrompt() -> String {
        if L10n.current == .zh {
            return """
            你是 MacPulse AI 的内置系统诊断代理「Pulse」，运行在用户的 macOS 应用内。你的职责：解读进程、分析 CPU/内存/磁盘占用、评估终止与清理风险、提出维护建议，以及**安全审计**（识别异常进程与提权行为、审查监听端口是否可疑、审计登录启动项、剪贴板内容查毒——钓鱼地址/危险命令/泄露密钥——这是应用「AI 查毒」功能的一部分，属于你的本职工作）。

            铁律（必须遵守）：
            1. 只回答与本机系统健康和信息安全相关的问题（进程/性能/维护/剪贴板内容安全）。任何其他话题（写代码、闲聊、新闻等）一律用一两句话礼貌说明超出职责范围，并引导回诊断主题。
            2. 你没有任何执行权限。若你判断某个进程应当被终止，必须在回复的末尾单独一行输出动作标记，格式严格如下（属性顺序可换）：
               <action action="quit" pid="12345"/>
               <action action="force_kill" pid="12345"/>
               quit=SIGTERM 温和退出；force_kill=SIGKILL 强制终止。一条标记对应一个 pid，仅在证据充分时输出，宁缺毋滥。标记会被应用拦截并由用户人工确认后才执行（human-in-the-loop），你永远不能直接执行任何操作。
            3. 只基于用户提供的进程数据引用 pid；数据之外的通用知识可以补充，但不确定时必须明说不确定，禁止编造。
            4. 这些系统关键进程一律提示不要终止：kernel_task、WindowServer、mds_stores、logd、sysmond、launchd、trustd、cloudd。
            5. 除终止进程外，你还可以提议清理与维护动作（同样必须经用户确认）：
               <action action="clean" target="app_caches|logs|dev_caches"/>   → 移入废纸篓（app_caches=应用缓存；logs=日志；dev_caches=Xcode/npm/gradle 等开发缓存）
               <action action="maintenance" task="purge_memory|flush_dns|empty_trash"/>   → purge 释放内存 / 刷新 DNS / 清空废纸篓
            6. 数据新鲜度工具：若提供的快照可能过期或需要最新数据，单独一行输出 <tool name="snapshot"/> —— 应用会立即回填最新实时摘要让你继续作答。每轮最多使用一次。
            7. 受控终端工具：需要底层信息或执行读写时，输出 <shell>命令</shell>（一条命令一个标签，可跨行）。命令经安全钩子分级：只读命令（ls/ps/lsof/cat/du/grep 等）自动执行并把输出回填给你；写操作与未知命令会请用户确认；危险命令（rm/sudo/管道执行脚本等）被直接拦截。禁止建议 rm —— 删除请改用 quit/force_kill 与 clean 动作。优先使用你已拥有的数据，仅在必要时使用该工具。
            7. 使用 Markdown，简洁分节（可用表格）；不要复述原始 JSON；语言跟随用户消息的语言。
            """
        }
        return """
        You are “Pulse”, the built-in diagnostics agent of the MacPulse AI app running on the user's Mac. Your job: interpret processes, analyze CPU/memory/disk usage, assess termination and cleanup risk, suggest maintenance steps, and perform **security audits** (spot anomalous processes and privilege behavior, review listening ports, audit login/startup items, clipboard poison check — part of the app's "AI poison check" feature and therefore in scope).

        Hard rules:
        1. Only answer questions about this machine's health and information security (processes/performance/maintenance/clipboard content safety). For anything else (coding help, small talk, news), politely say it is out of scope in one or two sentences and steer back to diagnostics.
        2. You have no execution capability. If you conclude a process should be terminated, end your reply with an action tag on its own line, exactly like (attribute order may vary):
           <action action="quit" pid="12345"/>
           <action action="force_kill" pid="12345"/>
           quit=SIGTERM; force_kill=SIGKILL. One tag per pid, only when evidence is clear. Tags are intercepted by the app and executed only after explicit human confirmation (human-in-the-loop) — you can never execute anything yourself.
        3. Reference pids only from the data provided; general knowledge is welcome but state uncertainty explicitly. Never fabricate.
        4. Always advise against terminating critical system processes: kernel_task, WindowServer, mds_stores, logd, sysmond, launchd, trustd, cloudd.
           5. Beyond terminating processes you may also propose cleanup and maintenance (also user-confirmed):
              <action action="clean" target="app_caches|logs|dev_caches"/>   → move to Trash (app_caches = application caches; logs; dev_caches = Xcode/npm/gradle dev caches)
              <action action="maintenance" task="purge_memory|flush_dns|empty_trash"/>   → purge memory / flush DNS / empty Trash
           6. Data freshness tool: if the provided snapshot looks stale or you need fresh numbers, output a single line exactly <tool name="snapshot"/> — the app will feed you a fresh live summary and you continue your answer. At most once per turn.
           7. Controlled terminal tool: when you need low-level data or a read/write operation, output <shell>command</shell> (one command per tag, may span lines). Commands pass a safety hook: read-only ones (ls/ps/lsof/cat/du/grep…) run automatically with output fed back to you; writes and unknown commands require user confirmation; dangerous ones (rm/sudo/piping scripts…) are blocked outright. Never suggest rm — use quit/force_kill and clean actions for deletions. Prefer data you already have; use this tool only when necessary.
           8. Use Markdown with concise sections (tables allowed); do not echo raw JSON; follow the user's language.
        """
    }

    /// 快照载荷 JSON（公开以便单测校验字段）。
    static func snapshotJSON(load: SystemLoad, procs: [ProcSample], includePath: Bool, cores: Int) -> String {
        var systemInfo: [String: Any] = ["user_cpu": round1(load.userPercent),
                                         "system_cpu": round1(load.systemPercent),
                                         "idle_cpu": round1(load.idlePercent),
                                         "cores": cores]
        if let free = DiskCleaner.volumeFreeBytes() {
            systemInfo["disk_free_gb"] = (Double(free) / 1_073_741_824 * 10).rounded() / 10
        }
        let payload: [String: Any] = [
            "system": systemInfo,
            "processes": procs.map { processJSON($0, includePath: includePath) }
        ]
        return payloadJSON(payload)
    }

    /// 首次整体分析的用户消息（附完整快照 JSON）。
    static func analysisUserMessage(load: SystemLoad, procs: [ProcSample], includePath: Bool, cores: Int) -> String {
        let json = snapshotJSON(load: load, procs: procs, includePath: includePath, cores: cores)
        if L10n.current == .zh {
            return """
            请分析当前系统占用。以下是按 CPU 降序的进程快照 JSON（macOS，\(cores) 逻辑核心）：
            \(json)
            要求：若判定任何具体进程应终止，必须在结论后逐个输出 <action/> 动作标记供我确认（系统关键进程除外）；不需要终止则可不输出。
            """
        }
        return """
        Please analyze the current CPU usage. Below is the process snapshot JSON sorted by CPU descending (macOS, \(cores) logical cores):
        \(json)
        Requirement: if you conclude any specific process should be terminated, output one <action/> tag per process after your conclusions (except critical system processes); omit tags if nothing should be terminated.
        """
    }

    /// 单进程解释的用户消息。
    static func explainUserMessage(proc: ProcSample, load: SystemLoad, includePath: Bool, cores: Int) -> String {
        let json = payloadJSON(["process": processJSON(proc, includePath: includePath),
                                "system_cpu_percent": round1(load.totalPercent),
                                "cores": cores])
        if L10n.current == .zh {
            return "请解释这个进程（它是什么、为什么占 CPU、能否安全终止）：\(json)"
        }
        return "Explain this process (what it is, why it uses CPU, whether it is safe to terminate): \(json)"
    }

    /// 磁盘分析的用户消息（携带可清理类别聚合与 Top 条目）。
    static func diskAnalysisUserMessage(freeGB: Double?, items: [DiskCleaner.Item]) -> String {
        var categories: [String: Any] = [:]
        for item in items {
            let key = item.category.rawValue
            var entry = categories[key] as? [String: Any] ?? ["count": 0, "bytes": 0]
            entry["count"] = (entry["count"] as? Int ?? 0) + 1
            entry["bytes"] = (entry["bytes"] as? Int64 ?? 0) + item.sizeBytes
            categories[key] = entry
        }
        let top = items.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(15).map { item -> [String: Any] in
            ["name": item.name, "category": item.category.rawValue,
             "size_mb": Int64((Double(item.sizeBytes) / 1_048_576).rounded()),
             "path": item.url.path]
        }
        var payload: [String: Any] = [
            "total_cleanable_gb": Double((Double(items.reduce(0) { $0 + $1.sizeBytes }) / 1_073_741_824 * 100).rounded() / 100),
            "categories": categories,
            "top_items": top
        ]
        if let freeGB { payload["disk_free_gb"] = freeGB }
        let json = payloadJSON(payload)
        if L10n.current == .zh {
            return """
            请分析本机磁盘的可清理空间（以下为扫描到的可再生缓存/日志，均为移入废纸篓且可恢复）：
            \(json)
            给出：是否建议清理、清理哪些类别、预估能释放多少空间；若有应执行的清理请输出对应动作标记供我确认。
            """
        }
        return """
        Please analyze the cleanable disk space below (scanned regenerable caches/logs; all removals go to Trash and are restorable):
        \(json)
        Tell me whether to clean, which categories, the estimated reclaim, and emit cleanup action tags for my confirmation if warranted.
        """
    }

    /// 安全体检的用户消息：进程 + 监听端口 + 磁盘 + 剪贴板发现（如有）。
    static func securityAuditUserMessage(load: SystemLoad, procs: [ProcSample],
                                         ports: [PortEntry], freeGB: Double?, swapText: String?,
                                         clipboardFindings: [ClipboardAuditor.Finding],
                                         clipboardRedacted: String?, includePath: Bool, cores: Int,
                                         loginItems: [LaunchItemScanner.LaunchItem] = []) -> String {
        var payload: [String: Any] = [
            "system": ["user_cpu": round1(load.userPercent),
                       "system_cpu": round1(load.systemPercent),
                       "idle_cpu": round1(load.idlePercent),
                       "cores": cores],
            "processes": procs.map { processJSON($0, includePath: includePath) },
            "listening_ports": ports.map { ["port": $0.port, "process": $0.process,
                                            "pid": Int($0.pid), "address": $0.address] }
        ]
        if let freeGB { payload["disk_free_gb"] = freeGB }
        if let swapText { payload["swap_usage"] = swapText }
        if !clipboardFindings.isEmpty || clipboardRedacted != nil {
            payload["clipboard"] = [
                "local_findings": clipboardFindings.map { ["type": $0.kind.rawValue, "preview": $0.redactedPreview] },
                "redacted_text": clipboardRedacted ?? ""
            ]
        }
        if !loginItems.isEmpty {
            payload["login_items"] = loginItems.map {
                ["label": $0.label, "scope": $0.scope.rawValue,
                 "path": $0.url.path, "suspicious_hint": $0.suspiciousHint ?? ""]
            }
        }
        let json = payloadJSON(payload)
        if L10n.current == .zh {
            let user = """
            请做一次系统安全体检。以下是当前进程快照（含 root 进程）、全部 TCP 监听端口、磁盘与剪贴板发现：
            \(json)
            要求输出：
            ## 可疑行为排序
            （表格：证据/风险 🔴🟡🟢；无明显异常就直说系统干净，不要编造）
            ## 逐项解读
            （重点解释 root 高占用、来源不明的进程与不常见的对外监听端口）
            ## 解决思路
            （给出处置方案；若判定应终止/清理，输出对应 <action/> 标记供我确认；不确定处明确说明需要进一步取证）
            """
            return user
        }
        let userEn = """
        Please run a security audit. Below are the process snapshot (including root processes), all TCP listening ports, disk and clipboard findings:
        \(json)
        Output:
        ## Suspicious Behavior Ranking
        (table: evidence / risk 🔴🟡🟢; if the system looks clean, say so plainly — never fabricate)
        ## Findings Explained
        (focus on root high-usage, unknown-origin processes and unusual externally-listening ports)
        ## Remediation
        (concrete plan; if a process should be terminated or caches cleaned, emit the matching <action/> tags for my confirmation; note explicitly where further evidence is needed)
        """
        return userEn
    }

    /// 轮间注入的紧凑上下文（控制 token），供后续对话跟踪最新状态。
    static func contextSummary(load: SystemLoad, procs: [ProcSample], limit: Int = 8) -> String {
        let rows = procs.prefix(limit).map { p in
            "- pid=\(p.pid) \(p.name) cpu=\(String(format: "%.1f", p.cpuPercent))% mem=\(Self.memoryMB(p.rssBytes))MB user=\(p.user)"
        }.joined(separator: "\n")
        let diskLine: String
        if let free = DiskCleaner.volumeFreeBytes() {
            let gb = (Double(free) / 1_073_741_824 * 10).rounded() / 10
            diskLine = L10n.s("磁盘剩余 \(gb)GB。可用清理类别：app_caches、logs、dev_caches。",
                              "Disk free: \(gb)GB. Cleanable categories: app_caches, logs, dev_caches.")
        } else {
            diskLine = ""
        }
        return L10n.s(
            "[实时上下文] 系统：用户 \(round1(load.userPercent))% / 系统 \(round1(load.systemPercent))%。\n\(diskLine)\nCPU Top \(min(limit, procs.count))：\n\(rows)",
            "[live context] system: user \(round1(load.userPercent))% / sys \(round1(load.systemPercent))%.\n\(diskLine)\nTop \(min(limit, procs.count)) by CPU:\n\(rows)"
        )
    }

    static func memoryMB(_ bytes: Int64) -> Int {
        Int((Double(bytes) / 1_048_576).rounded())
    }
}
