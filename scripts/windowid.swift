// 打印 MacPulse 主窗口的 CGWindowID，给 screencapture -l 用。
// 按窗口面积取最大的那个（排除阴影/工具窗）。
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MacPulse"
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                            kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
var best: (id: Int, area: Double)?
for w in list {
    guard let name = w[kCGWindowOwnerName as String] as? String, name.contains(owner),
          let id = w[kCGWindowNumber as String] as? Int,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let width = b["Width"] as? Double, let height = b["Height"] as? Double
    else { continue }
    let area = width * height
    if area > (best?.area ?? 0) { best = (id, area) }
}
guard let best else { exit(1) }
print(best.id)
