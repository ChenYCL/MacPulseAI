import AppKit
import Foundation

/// 技能：挂在某一界上的一段可复用 AI 任务。
///
/// 安全边界（这条是整个设计的前提）：技能**只是一段提示词**，导入技能不会、
/// 也不能让它直接执行任何东西。技能能做的全部事情就是「把这段话连同本界的
/// 上下文发给模型」。模型随后提出的终止 / 清理 / shell 动作，仍旧逐条走原来的
/// HITL 确认卡与 ShellGuard 裁决——和你自己在对话框里打字是完全一样的路径。
/// 所以从别人那儿拿一个 .json 回来导入，最坏情况是浪费一次 token，而不是被执行。
struct Skill: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var detail: String
    /// SF Symbol 名；导入时校验，认不出来就退回 sparkles。
    var icon: String
    /// 挂在哪一界（AppView.Pane 的 rawValue）；留空表示每一界都出现。
    var pane: String
    var prompt: String
    /// 内置技能不可删除，也不写盘。
    var builtIn: Bool = false

    enum CodingKeys: String, CodingKey { case id, name, detail, icon, pane, prompt }

    /// 导入校验：字段缺失/超长/图标不存在都在这里被收敛掉，
    /// 而不是等到渲染时炸出一个空按钮。返回 nil = 这份文件不是合法技能。
    static func validated(_ raw: Skill) -> Skill? {
        let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = raw.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty, prompt.count <= 4000 else { return nil }

        let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = id.isEmpty ? UUID().uuidString : id
        // 文件名安全：技能 id 会变成磁盘上的文件名，不能带路径分隔符。
        let safeID = slug.components(separatedBy: CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_")).inverted)
            .joined(separator: "-")
        guard !safeID.isEmpty else { return nil }

        let pane = AppView.Pane(rawValue: raw.pane) != nil ? raw.pane : ""
        let icon = NSImage(systemSymbolName: raw.icon, accessibilityDescription: nil) != nil
            ? raw.icon : "sparkles"

        return Skill(id: safeID,
                     name: String(name.prefix(24)),
                     detail: String(raw.detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
                     icon: icon,
                     pane: pane,
                     prompt: prompt)
    }
}

/// 技能库：内置技能 + 用户从 .json 导入的技能。
@MainActor
final class SkillStore: ObservableObject {
    @Published private(set) var imported: [Skill] = []
    @Published var lastMessage: String?

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacPulse/Skills", isDirectory: true)
    }()

    init() { reload() }

    // MARK: 读取

    /// 某一界可用的技能：内置在前，导入的在后。
    func skills(for pane: AppView.Pane) -> [Skill] {
        Self.builtIn(for: pane) + imported.filter { $0.pane.isEmpty || $0.pane == pane.rawValue }
    }

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.directory,
                                                      includingPropertiesForKeys: nil) else {
            imported = []
            return
        }
        var loaded: [Skill] = []
        for url in files where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONDecoder().decode(Skill.self, from: data),
                  let ok = Skill.validated(raw) else { continue }
            loaded.append(ok)
        }
        imported = loaded.sorted { $0.name < $1.name }
    }

    // MARK: 导入 / 删除

    /// 从文件导入。返回成功条数；失败原因写进 lastMessage 而不是静默吞掉。
    @discardableResult
    func importSkills(from urls: [URL]) -> Int {
        var ok = 0, bad = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { bad += 1; continue }
            // 单个技能或一个技能数组都收
            let candidates: [Skill]
            if let one = try? JSONDecoder().decode(Skill.self, from: data) {
                candidates = [one]
            } else if let many = try? JSONDecoder().decode([Skill].self, from: data) {
                candidates = many
            } else {
                bad += 1
                continue
            }
            for candidate in candidates {
                guard let skill = Skill.validated(candidate) else { bad += 1; continue }
                if save(skill) { ok += 1 } else { bad += 1 }
            }
        }
        reload()
        lastMessage = bad == 0
            ? L10n.s("已导入 \(ok) 个技能", "Imported \(ok) skill(s)")
            : L10n.s("已导入 \(ok) 个技能，\(bad) 个被跳过（字段缺失或格式不对）",
                     "Imported \(ok) skill(s); skipped \(bad) (missing fields or bad format)")
        return ok
    }

    private func save(_ skill: Skill) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(skill)
            try data.write(to: Self.directory.appendingPathComponent("\(skill.id).json"),
                           options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func remove(_ skill: Skill) {
        guard !skill.builtIn else { return }
        let url = Self.directory.appendingPathComponent("\(skill.id).json")
        // 删自己写的技能文件，进废纸篓而不是抹掉——和本应用其他删除路径保持一致。
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
        lastMessage = L10n.s("已移除技能「\(skill.name)」（在废纸篓里）",
                             "Removed “\(skill.name)” (it's in the Trash)")
    }

    func revealDirectory() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.directory])
    }

    // MARK: 内置技能

    /// 每一界带两个开箱可用的技能，免得首次打开是一排空槽。
    /// 它们和导入的技能走完全相同的执行路径——没有隐藏能力。
    static func builtIn(for pane: AppView.Pane) -> [Skill] {
        func s(_ id: String, _ icon: String, _ name: String, _ detail: String, _ prompt: String) -> Skill {
            Skill(id: id, name: name, detail: detail, icon: icon,
                  pane: pane.rawValue, prompt: prompt, builtIn: true)
        }
        switch pane {
        case .status:
            return [
                s("builtin-status-hogs", "flame",
                  L10n.s("揪出耗电大户", "Power hogs"),
                  L10n.s("按 CPU 排序解释谁在烧电池，并说明哪些可以安全退出",
                         "Explain what's burning battery and what's safe to quit"),
                  L10n.s("结合当前进程快照，找出最耗 CPU 的几个进程，逐个说明它是什么、为什么在跑、可不可以安全退出。不确定的直接说不确定。",
                         "From the current process snapshot, find the top CPU consumers. For each, explain what it is, why it's running, and whether it's safe to quit. Say so plainly when you're unsure.")),
                s("builtin-status-root", "lock.shield",
                  L10n.s("认领 root 进程", "Own the root procs"),
                  L10n.s("逐个解释常驻的 root 进程属于哪个软件",
                         "Attribute each long-running root process to a vendor"),
                  L10n.s("列出当前以 root 运行的常驻进程，逐个说明它属于哪个软件、是系统自带还是第三方装的、有没有值得怀疑的。",
                         "List the long-running root processes. For each, say which software owns it, whether it ships with macOS or was installed, and whether anything looks off."))
            ]
        case .clean:
            return [
                s("builtin-clean-risk", "questionmark.folder",
                  L10n.s("删了会怎样", "What breaks?"),
                  L10n.s("逐类说明清掉这些缓存之后会发生什么",
                         "Explain the consequence of clearing each category"),
                  L10n.s("针对当前扫描出的可清理项，逐类说明：清掉之后会发生什么、下次什么时候会重新生成、有没有哪一类我不该动。",
                         "For each scanned junk category: what happens after clearing it, when it regenerates, and whether any category I should leave alone.")),
                s("builtin-clean-biggest", "chart.bar",
                  L10n.s("先清哪个最划算", "Best value first"),
                  L10n.s("按「省的空间 / 风险」排序给出清理顺序",
                         "Rank cleanup order by space-freed over risk"),
                  L10n.s("按「能省多少空间 ÷ 风险」给当前可清理项排个先后顺序，说明理由。",
                         "Rank the scanned items by space-freed over risk and explain the ordering."))
            ]
        case .software:
            return [
                s("builtin-software-slim", "scissors",
                  L10n.s("哪些能卸", "What can go"),
                  L10n.s("审查已装应用，指出重复的、废弃的、有风险的",
                         "Flag duplicate, abandoned, or risky installed apps"),
                  L10n.s("审查我已安装的应用清单，指出：功能重复的、看起来很久没用的、来路可疑的。给出卸载建议和理由，不确定的标注出来。",
                         "Review my installed apps and flag duplicates, likely-unused ones, and anything of dubious origin. Recommend what to uninstall and why; mark anything you're unsure about.")),
                s("builtin-software-startup", "bolt.badge.clock",
                  L10n.s("开机自启体检", "Login item audit"),
                  L10n.s("解释每个启动项是谁装的、能不能关",
                         "Explain who installed each login item and whether it can go"),
                  L10n.s("逐个解释我的启动项：它属于哪个软件、关掉之后会失去什么功能、有没有必要开机就跑。",
                         "For each login item: which app owns it, what I lose by disabling it, and whether it really needs to run at login."))
            ]
        case .optimize:
            return [
                s("builtin-optimize-plan", "list.bullet.clipboard",
                  L10n.s("现在该做什么", "What now?"),
                  L10n.s("按当前负载给出该跑哪几个维护动作",
                         "Recommend maintenance actions for the current state"),
                  L10n.s("基于当前的 CPU / 内存 / 磁盘状态，告诉我现在值得跑哪几个维护动作、跑完预期改善什么、哪些现在跑没意义。",
                         "Given current CPU/memory/disk state, tell me which maintenance actions are worth running now, what each should improve, and which are pointless right now.")),
                s("builtin-optimize-slow", "tortoise",
                  L10n.s("为什么变慢了", "Why is it slow?"),
                  L10n.s("从负载、内存压力、磁盘余量三条线索排查",
                         "Diagnose across load, memory pressure, and free space"),
                  L10n.s("我觉得机器变慢了。请从 CPU 负载、内存压力（含 swap）、磁盘余量三个方向排查，指出最可能的瓶颈和证据。",
                         "My Mac feels slow. Diagnose across CPU load, memory pressure (incl. swap), and free disk space; name the most likely bottleneck and cite the evidence."))
            ]
        case .analyze:
            return [
                s("builtin-analyze-why", "externaldrive.badge.questionmark",
                  L10n.s("磁盘怎么满的", "Where did it go?"),
                  L10n.s("解读当前目录的空间去向并指出可回收的",
                         "Interpret the current folder and flag reclaimable space"),
                  L10n.s("解读当前目录的空间去向：哪几个占大头、分别是什么东西、哪些是可以安全回收的、哪些动不得。",
                         "Interpret where space went in this folder: the biggest consumers, what each is, what's safely reclaimable, and what must stay.")),
                s("builtin-analyze-dev", "hammer",
                  L10n.s("开发垃圾", "Dev leftovers"),
                  L10n.s("找出构建产物、依赖缓存、镜像等可再生目录",
                         "Find regenerable build output, dep caches, images"),
                  L10n.s("在当前目录里找出典型的开发产物：node_modules、构建输出、依赖缓存、容器镜像等，说明哪些删掉可以重新生成。",
                         "Find typical dev artifacts here — node_modules, build output, dependency caches, container images — and say which regenerate after deletion."))
            ]
        case .security:
            return [
                s("builtin-security-exposure", "network.badge.shield.half.filled",
                  L10n.s("暴露面体检", "Exposure check"),
                  L10n.s("逐个端口说明是否应该对外监听",
                         "Judge every listening port's exposure"),
                  L10n.s("逐个检查当前监听端口：绑在 127.0.0.1 还是 0.0.0.0、属于哪个进程、有没有必要对局域网开放。把该收回本地的挑出来。",
                         "Go through every listening port: bound to 127.0.0.1 or 0.0.0.0, which process owns it, and whether LAN exposure is warranted. Call out what should be local-only.")),
                s("builtin-security-persist", "arrow.triangle.2.circlepath.circle",
                  L10n.s("查常驻手段", "Persistence check"),
                  L10n.s("从启动项和常驻进程里找可疑的持久化",
                         "Hunt persistence across login items and daemons"),
                  L10n.s("从启动项和常驻进程里找可疑的持久化手段：路径不在标准位置的、没有签名主体的、名字像系统组件但其实不是的。给证据。",
                         "Hunt for suspicious persistence across login items and resident processes: non-standard paths, unsigned owners, names that mimic system components. Cite evidence."))
            ]
        }
    }
}
