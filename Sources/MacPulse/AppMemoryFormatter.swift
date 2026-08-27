import Foundation

/// 统一的字节格式化工具（供进程表与磁盘页共用）。
enum AppMemoryFormatter {
    static func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
