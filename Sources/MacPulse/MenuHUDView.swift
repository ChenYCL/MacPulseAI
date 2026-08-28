import AppKit
import SwiftUI

/// 菜单栏 HUD：影棚白底 + 火候/水腑/土库三块读数 + Top 进程 + 六界快捷入口。
struct MenuHUDView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var disk: DiskModel
    let onOpenMainWindow: () -> Void
    let onOpenPane: (AppView.Pane) -> Void
    let onQuit: () -> Void
    @State private var hudPane: AppView.Pane = .status

    private var topProcesses: [ProcSample] {
        Array(model.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5))
    }

    private var fire: WuXingTheme.Theme { WuXingTheme.theme(for: .status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 8) {
                tile(theme: fire,
                     title: L10n.s("火候", "CPU"),
                     value: String(format: "%.0f%%", model.load.totalPercent),
                     detail: String(format: L10n.s("用户 %.0f · 系统 %.0f", "user %.0f · sys %.0f"),
                                    model.load.userPercent, model.load.systemPercent),
                     ratio: model.load.totalPercent / 100)
                tile(theme: WuXingTheme.theme(for: .analyze),
                     title: L10n.s("水腑", "MEM"),
                     value: String(format: "%.0f%%", model.memoryUsedPercent ?? 0),
                     detail: model.swapUsedText.map { L10n.s("swap \($0)", "swap \($0)") }
                        ?? L10n.s("无换页", "no swap"),
                     ratio: (model.memoryUsedPercent ?? 0) / 100)
                tile(theme: WuXingTheme.theme(for: .optimize),
                     title: L10n.s("土库", "DISK"),
                     value: disk.freeBytesText,
                     detail: L10n.s("可用空间", "available"),
                     ratio: nil)
            }

            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(L10n.s("TOP 进程", "TOP PROCESSES"))
                ForEach(topProcesses, id: \.pid) { p in
                    HStack(spacing: 6) {
                        Circle().fill(fire.primary.opacity(0.85)).frame(width: 5, height: 5)
                        Text(p.name).font(.caption).foregroundColor(Studio.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(String(format: "%.1f%%", p.cpuPercent))
                            .font(Studio.value(10.5)).foregroundColor(Studio.inkSecondary)
                    }
                }
                if topProcesses.isEmpty {
                    Text(L10n.s("采样中…", "Sampling…"))
                        .font(.caption).foregroundColor(Studio.inkTertiary)
                }
            }

            Rectangle().fill(Studio.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 7) {
                SectionLabel(L10n.s("六界", "REALMS"))
                RealmPicker(selection: $hudPane, size: 34, onPick: { onOpenPane($0) })
            }

            HStack {
                Button(L10n.s("打开主窗口", "Open Main Window")) { onOpenMainWindow() }
                    .buttonStyle(.studioSecondary)
                Spacer()
                Button(L10n.s("退出", "Quit")) { onQuit() }
                    .buttonStyle(.studioQuiet)
            }
        }
        .padding(14)
        .frame(width: 340)
        .fixedSize(horizontal: true, vertical: true)
        .background(Studio.surface)
        .onAppear { disk.refreshFreeBytes() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            BeastAvatar(theme: fire, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.s("MacPulse · 五气朝元", "MacPulse · Five Elements"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Studio.ink)
                Text(L10n.s("五行就位，系统安泰", "Five elements in balance"))
                    .font(.caption2).foregroundColor(Studio.inkTertiary)
            }
            Spacer()
        }
    }

    private func tile(theme: WuXingTheme.Theme, title: String, value: String,
                      detail: String, ratio: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(title, tint: theme.primary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(Studio.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Capsule().fill(Studio.surfaceSunken).frame(height: 4)
                .overlay(alignment: .leading) {
                    if let ratio {
                        GeometryReader { geo in
                            Capsule()
                                .fill(theme.primary)
                                .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, ratio)))))
                        }
                    }
                }
            Text(detail).font(.caption2).foregroundColor(Studio.inkTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: Studio.radiusSlot, style: .continuous)
            .fill(Studio.surfaceMuted))
        .overlay(RoundedRectangle(cornerRadius: Studio.radiusSlot, style: .continuous)
            .strokeBorder(Studio.hairline, lineWidth: 1))
    }
}
