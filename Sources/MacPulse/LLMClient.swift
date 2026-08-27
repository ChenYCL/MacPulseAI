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
    /// 思考型模型 max_tokens 截断时自动翻倍重试一次。
    /// Anthropic 协议会把 role==system 的消息抽出为顶层 system 参数。
    func stream(messages: [LLMMessage], onDelta: @escaping (String) -> Void) async throws -> String
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

    func stream(messages: [LLMMessage], onDelta: @escaping (String) -> Void) async throws -> String {
        do {
            return try await streamOnce(maxTokens: 4096, messages: messages, onDelta: onDelta)
        } catch LLMError.reasoningOnly {
            return try await streamOnce(maxTokens: 8192, messages: messages, onDelta: onDelta)
        }
    }

    private func makeRequest(maxTokens: Int, stream: Bool, messages: [LLMMessage]) throws -> URLRequest {
        let base = try normalizedBase(config.baseURL)
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.badURL(config.baseURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = stream ? 600 : 60
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

    private func streamOnce(maxTokens: Int, messages: [LLMMessage], onDelta: @escaping (String) -> Void) async throws -> String {
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
        return try acc.finalize()
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

    func stream(messages: [LLMMessage], onDelta: @escaping (String) -> Void) async throws -> String {
        // role==system 的消息抽取为 Anthropic 顶层 system 参数
        let system = messages.filter { $0.role == .system }.map { $0.content }.joined(separator: "\n\n")
        let chat = messages.filter { $0.role != .system }
        do {
            return try await streamOnce(maxTokens: 4096, system: system, chat: chat, onDelta: onDelta)
        } catch LLMError.reasoningOnly {
            return try await streamOnce(maxTokens: 8192, system: system, chat: chat, onDelta: onDelta)
        }
    }

    private func makeRequest(maxTokens: Int, stream: Bool, system: String?, chat: [LLMMessage]) throws -> URLRequest {
        let url = try messagesURL()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = stream ? 600 : 60
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

    private func streamOnce(maxTokens: Int, system: String, chat: [LLMMessage], onDelta: @escaping (String) -> Void) async throws -> String {
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
        return try acc.finalize()
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
    func finalize() throws -> String {
        if !text.isEmpty { return text }
        if let errText = streamError {
            throw LLMError.invalidResponse(errText)
        }
        if !reasoning.isEmpty { throw LLMError.reasoningOnly(reasoning) }
        if stopReason == "max_tokens" || stopReason == "length" {
            throw LLMError.reasoningOnly(L10n.s("（响应因 max_tokens 截断）", "(response truncated by max_tokens)"))
        }
        throw LLMError.emptyResponse
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
            你是 MacPulse AI 的内置系统诊断代理「Pulse」，运行在用户的 macOS 应用内。你的职责：解读进程、分析 CPU/内存/磁盘占用、评估终止与清理风险、提出维护建议，以及**剪贴板内容的安全审查**（识别钓鱼地址、危险命令、泄露的密钥——这是应用「AI 查毒」功能的一部分，属于你的本职工作）。

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
            7. 使用 Markdown，简洁分节（可用表格）；不要复述原始 JSON；语言跟随用户消息的语言。
            """
        }
        return """
        You are “Pulse”, the built-in diagnostics agent of the MacPulse AI app running on the user's Mac. Your job: interpret processes, analyze CPU/memory/disk usage, assess termination and cleanup risk, suggest maintenance steps, and perform **clipboard content security reviews** (detecting phishing addresses, dangerous commands, leaked secrets — part of the app's "AI poison check" feature and therefore in scope).

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
           7. Use Markdown with concise sections (tables allowed); do not echo raw JSON; follow the user's language.
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
