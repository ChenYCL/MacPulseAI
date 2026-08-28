import Foundation

/// 一个被采样的进程快照。
struct ProcSample: Identifiable, Hashable {
    let pid: Int32
    var name: String       // 展示名（完整路径的最后一段，缺省用 ps ucomm）
    var path: String       // 完整可执行路径（proc_pidpath），可能为空
    var user: String
    var uid: UInt32
    var isOwnedByMe: Bool  // uid == 当前用户；非本用户的进程不可终止（需 root）
    var cpuPercent: Double // 瞬时 CPU（两次采样差值），首采为 ps 生命周期均值
    var memPercent: Double
    var rssBytes: Int64
    var threads: Int       // 仅当前用户进程可读（libproc），其他用户为 0，UI 显示 "—"
    var state: String      // ps 单字母状态：R/S/U/T/Z...
    var id: Int32 { pid }
}

/// 系统级 CPU 负载（百分比）。
struct SystemLoad: Hashable {
    var userPercent: Double = 0
    var systemPercent: Double = 0
    var idlePercent: Double = 100

    var totalPercent: Double { max(0, min(100, userPercent + systemPercent)) }
    static let zero = SystemLoad()

    /// 稳定到 0.1%，避免亚像素抖动触发 SwiftUI 全树重绘。
    func snapped() -> SystemLoad {
        SystemLoad(userPercent: (userPercent * 10).rounded() / 10,
                   systemPercent: (systemPercent * 10).rounded() / 10,
                   idlePercent: (idlePercent * 10).rounded() / 10)
    }
}
