import Foundation

// MARK: - 配置与协议

struct LLMConfig {
    var provider: Settings.ProviderKind
    var baseURL: String
    var apiKey: String
    var model: String
}

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

protocol LLMServicing {
    /// 非流式补全（一次性返回）。适合轻量探测（如「测试连接」）。
    func complete(system: String, user: String) async throws -> String

    /// 流式补全：每收到增量通过 onDelta 回调（增量片段），最终返回拼接后的完整文本。
    /// 思考型模型 max_tokens 截断时自动翻倍重试一次；请求保持长连接，不被网关长时间静默掐断。
    func stream(system: String, user: String, onDelta: @escaping (String) -> Void) async throws -> String
}

enum LLMServiceFactory {
    static func service(for config: LLMConfig, session: URLSession = .shared) -> LLMServicing {
        switch config.provider {
        case .openAICompatible: return OpenAIService(config: config, session: session)
        case .anthropic: return AnthropicService(config: config, session: session)
        }
    }
}

/// 去除首尾斜杠，供拼接路径使用。
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

    /// 流式补全：SSE 逐块回调；网关不支持流式时自动回落普通 JSON 解析；
    /// 思考型模型 max_tokens 截断时自动翻倍重试一次。
    func stream(system: String, user: String, onDelta: @escaping (String) -> Void) async throws -> String {
        do {
            return try await streamOnce(maxTokens: 4096, system: system, user: user, onDelta: onDelta)
        } catch LLMError.reasoningOnly {
            return try await streamOnce(maxTokens: 8192, system: system, user: user, onDelta: onDelta)
        }
    }

    private func streamOnce(maxTokens: Int, system: String, user: String, onDelta: @escaping (String) -> Void) async throws -> String {
        let base = try normalizedBase(config.baseURL)
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.badURL(config.baseURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(model: config.model,
                              temperature: 0.3,
                              maxTokens: maxTokens,
                              stream: true,
                              messages: [.init(role: "system", content: system),
                                         .init(role: "user", content: user)])
        )

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

    /// 首次 max_tokens 不足导致思考型模型只产出思考内容时，自动翻倍重试一次。
    func complete(system: String, user: String) async throws -> String {
        do {
            return try await send(maxTokens: 4096, system: system, user: user)
        } catch LLMError.reasoningOnly {
            return try await send(maxTokens: 8192, system: system, user: user)
        }
    }

    private func send(maxTokens: Int, system: String, user: String) async throws -> String {
        let base = try normalizedBase(config.baseURL)
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.badURL(config.baseURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(model: config.model,
                              temperature: 0.3,
                              maxTokens: maxTokens,
                              stream: false,
                              messages: [.init(role: "system", content: system),
                                         .init(role: "user", content: user)])
        )

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.invalidResponse("非 HTTP 响应") }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            guard let choice = decoded.choices.first else { throw LLMError.emptyResponse }
            if let content = choice.message.content, !content.isEmpty { return content }
            // 思考型模型兜底：content 为空但有独立推理字段/被 max_tokens 截断
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

    func messagesURL() throws -> URL {
        let base = try normalizedBase(config.baseURL)
        let path = base.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        guard let url = URL(string: base + path) else { throw LLMError.badURL(config.baseURL) }
        return url
    }

    /// 流式补全：SSE 逐块回调；网关不支持流式时自动回落普通 JSON 解析；
    /// 思考型模型 max_tokens 截断时自动翻倍重试一次。
    func stream(system: String, user: String, onDelta: @escaping (String) -> Void) async throws -> String {
        do {
            return try await streamOnce(maxTokens: 4096, system: system, user: user, onDelta: onDelta)
        } catch LLMError.reasoningOnly {
            return try await streamOnce(maxTokens: 8192, system: system, user: user, onDelta: onDelta)
        }
    }

    private func streamOnce(maxTokens: Int, system: String, user: String, onDelta: @escaping (String) -> Void) async throws -> String {
        let url = try messagesURL()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !config.apiKey.isEmpty {
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.httpBody = try JSONEncoder().encode(
            AnthropicRequest(model: config.model,
                             maxTokens: maxTokens,
                             stream: true,
                             system: system,
                             messages: [.init(role: "user", content: user)])
        )

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

    /// 首次 max_tokens 不足导致思考型模型只产出思考内容时，自动翻倍重试一次。
    func complete(system: String, user: String) async throws -> String {
        do {
            return try await send(maxTokens: 4096, system: system, user: user)
        } catch LLMError.reasoningOnly {
            return try await send(maxTokens: 8192, system: system, user: user)
        }
    }

    private func send(maxTokens: Int, system: String, user: String) async throws -> String {
        let url = try messagesURL()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !config.apiKey.isEmpty {
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.httpBody = try JSONEncoder().encode(
            AnthropicRequest(model: config.model,
                             maxTokens: maxTokens,
                             stream: false,
                             system: system,
                             messages: [.init(role: "user", content: user)])
        )

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.invalidResponse("非 HTTP 响应") }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            // 正文：拼接所有 text 块
            let text = decoded.content.filter { ($0.type == nil || $0.type == "text") }
                .compactMap { $0.text }.joined()
            if !text.isEmpty { return text }

            // 思考型模型兜底：max_tokens 可能在思考阶段耗尽导致正文为空
            let reasoning = decoded.content.compactMap { $0.thinking }.joined()
            if !reasoning.isEmpty {
                throw LLMError.reasoningOnly(reasoning)
            }
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
}

// MARK: - SSE 流式解析（纯函数，便于单测）

/// 流式会话的累计状态与判定逻辑。
struct SSEAccumulator {
    var text = ""
    var reasoning = ""
    var stopReason: String?
    /// 网关不支持 stream 时会整段返回普通 JSON；记录以便回落解析。
    var sawNonSSEBody = false
    var onDelta: ((String) -> Void)?

    mutating func absorbOpenAIChunk(jsonData: String) throws {
        let trimmed = jsonData.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "[DONE]" else { return }
        sawNonSSEBody = false
        guard let data = trimmed.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
              let choice = chunk.choices?.first else {
            // 网关忽略 stream=true 返回了完整 JSON 响应 → 整体作为正文回落
            if let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
               obj["choices"] != nil { sawNonSSEBody = true }
            return
        }
        if let d = choice.delta?.content, !d.isEmpty {
            text += d
            onDelta?(d)
        }
        if let r = choice.delta?.reasoning_content, !r.isEmpty { reasoning += r }
        if let f = choice.finish_reason { stopReason = f }
    }

    mutating func absorbAnthropicEvent(jsonPayload: String) throws {
        let trimmed = jsonPayload.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let event = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: data) else {
            return
        }
        switch event.type {
        case "content_block_delta":
            if let t = event.delta?.text, !t.isEmpty {
                text += t
                onDelta?(t)
            }
            if let th = event.delta?.thinking, !th.isEmpty { reasoning += th }
        case "message_delta":
            if let sr = event.delta?.stop_reason { stopReason = sr }
        default:
            break
        }
    }

    /// 结束时判定正文；思考-only/截断等情况抛出可操作的错误。
    func finalize() throws -> String {
        if !text.isEmpty { return text }
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
    let type: String?
    let delta: Delta?
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
    let choices: [Choice]?
}

// MARK: - Prompt 构建

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

    static func analysisPayloadJSON(load: SystemLoad, procs: [ProcSample], includePath: Bool, cores: Int) -> String {
        let payload: [String: Any] = [
            "system": ["user_cpu": round1(load.userPercent),
                       "system_cpu": round1(load.systemPercent),
                       "idle_cpu": round1(load.idlePercent),
                       "cores": cores],
            "processes": procs.map { processJSON($0, includePath: includePath) }
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func analysisPrompt(load: SystemLoad, procs: [ProcSample], includePath: Bool, cores: Int) -> (system: String, user: String) {
        let system: String
        let user: String
        if L10n.current == .zh {
            system = """
            你是 macOS 系统诊断助手，帮助用户分析当前占用 CPU 的进程。请用简体中文、Markdown 输出，结构如下：
            ## 总体判断
            系统负载情况与最可疑的 1-3 个进程。
            ## 进程解读
            逐个解释高占用进程是什么、为什么可能占用高（基于你的知识；不确定时明确说不确定）。
            ## 建议
            可执行的建议清单，每条末尾标注风险：🔴 高危（不建议动）/ 🟡 谨慎（可能丢数据）/ 🟢 可安全终止。
            注意：系统关键进程（kernel_task、WindowServer、mds_stores、logd、sysmond 等）必须提示不要随意终止；你只能给出建议，无法执行任何操作，请提醒用户自行决定。
            """
            user = """
            当前是 macOS（\(cores) 逻辑核心）。以下为按 CPU 降序排列的进程快照 JSON：
            \(analysisPayloadJSON(load: load, procs: procs, includePath: includePath, cores: cores))
            请按系统提示的结构输出分析。
            """
        } else {
            system = """
            You are a macOS system diagnostics assistant helping the user analyze CPU-hungry processes. Answer in Markdown with exactly this structure:
            ## Overall Assessment
            System load and the 1-3 most suspicious processes.
            ## Process Breakdown
            Explain each high-usage process: what it is and why it may be busy (based on your knowledge; say so explicitly when unsure).
            ## Recommendations
            An actionable list; mark each item with risk: 🔴 high risk (leave it alone) / 🟡 caution (may lose data) / 🟢 safe to terminate.
            Note: critical system processes (kernel_task, WindowServer, mds_stores, logd, sysmond, etc.) must be flagged as "do not terminate"; you can only advise — you cannot perform any action — remind the user to decide themselves.
            """
            user = """
            This is macOS (\(cores) logical cores). Below is a process snapshot JSON sorted by CPU descending:
            \(analysisPayloadJSON(load: load, procs: procs, includePath: includePath, cores: cores))
            Follow the system prompt structure for your analysis.
            """
        }
        return (system, user)
    }

    static func explainPayloadJSON(proc: ProcSample, load: SystemLoad, includePath: Bool, cores: Int) -> String {
        let payload: [String: Any] = [
            "system_cpu_percent": round1(load.totalPercent),
            "cores": cores,
            "process": processJSON(proc, includePath: includePath)
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func explainPrompt(proc: ProcSample, load: SystemLoad, includePath: Bool, cores: Int) -> (system: String, user: String) {
        let system: String
        let user: String
        if L10n.current == .zh {
            system = """
            你是 macOS 进程解释助手。用简体中文回答：该进程是什么、为什么可能占用 CPU、是否可以安全终止。2-4 句话，末尾用 🟢（可安全终止）/ 🟡（谨慎）/ 🔴（不要终止）标注。不确定时明确说不确定，不要编造。
            """
            user = "请解释这个进程：\(explainPayloadJSON(proc: proc, load: load, includePath: includePath, cores: cores))"
        } else {
            system = """
            You are a macOS process explainer. Answer in English: what this process is, why it may use CPU, and whether it is safe to terminate. 2-4 sentences, ending with 🟢 (safe to quit) / 🟡 (caution) / 🔴 (do not terminate). Say so explicitly when unsure; never fabricate.
            """
            user = "Explain this process: \(explainPayloadJSON(proc: proc, load: load, includePath: includePath, cores: cores))"
        }
        return (system, user)
    }
}
