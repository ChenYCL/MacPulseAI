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
        case .invalidResponse(let detail):
            let preview = String(detail.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            return L10n.s("响应解析失败：\(preview)", "Failed to parse response: \(preview)")
        }
    }
}

protocol LLMServicing {
    /// 发送一次补全请求，返回模型文本输出。
    func complete(system: String, user: String) async throws -> String
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
    let messages: [Message]
}

struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
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

    func complete(system: String, user: String) async throws -> String {
        let base = try normalizedBase(config.baseURL)
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.badURL(config.baseURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(
            OpenAIChatRequest(model: config.model,
                              temperature: 0.3,
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
            guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
                throw LLMError.emptyResponse
            }
            return content
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
    let system: String?
    let messages: [Message]
}

struct AnthropicResponse: Decodable {
    struct Block: Decodable {
        let type: String?
        let text: String?
    }
    let content: [Block]
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

    func complete(system: String, user: String) async throws -> String {
        let url = try messagesURL()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !config.apiKey.isEmpty {
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        }
        req.httpBody = try JSONEncoder().encode(
            AnthropicRequest(model: config.model,
                             max_tokens: 1024,
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
            let text = decoded.content.filter { $0.type == nil || $0.type == "text" }
                .compactMap { $0.text }.joined()
            guard !text.isEmpty else { throw LLMError.emptyResponse }
            return text
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.invalidResponse(String(data: data, encoding: .utf8) ?? "\(error)")
        }
    }
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
