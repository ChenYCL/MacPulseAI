import AppKit
import SwiftUI

/// 顶栏读数（Equatable）：数值稳定到 0.1 再比较——亚 0.1% 的抖动只制造重绘，没有信息量。
struct StatValue: Equatable {
    let user: Double, sys: Double, idle: Double
    init(_ l: SystemLoad) {
        user = (l.userPercent * 10).rounded() / 10
        sys = (l.systemPercent * 10).rounded() / 10
        idle = (l.idlePercent * 10).rounded() / 10
    }
    var total: Double { max(0, 100 - idle) }
}

/// 顶栏：左边品牌，正中一排文字标签，右边活体读数与开关。
/// 参考里的导航条就是纯文字 + 选中项一条蓝下划线，除此之外什么都不画。
struct TopNavBar: View {
    let stat: StatValue
    let memPercent: Double?
    let isPaused: Bool
    let theme: WuXingTheme.Theme
    /// 当前是否停在选择台（选择台标签高亮）。
    let onRoster: Bool
    let activePane: AppView.Pane
    let onSelectRoster: () -> Void
    let onSelectPane: (AppView.Pane) -> Void
    let onPause: () -> Void
    let onSettings: () -> Void

    @Namespace private var underline

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                brand
                Spacer(minLength: 12)
                trailing
            }
            tabs
        }
        .padding(.leading, 78)          // 让开交通灯
        .padding(.trailing, 14)
        .frame(height: 54)
        // 顶栏不做成一条独立的白带：背景纸从导航底下连续地铺下去。
        .background(Color.clear)
    }

    // MARK: 品牌

    private var brand: some View {
        HStack(spacing: 9) {
            BeastAvatar(theme: theme, size: 28)
            VStack(alignment: .leading, spacing: -1) {
                Text("MacPulse")
                    .font(Studio.display(15, weight: .semibold))
                    .foregroundColor(Studio.ink)
                Text(L10n.s("五气朝元", "FIVE ELEMENTS"))
                    .font(Studio.microLabel(8.5))
                    .tracking(1.2)
                    .foregroundColor(Studio.inkTertiary)
            }
        }
        .fixedSize()
    }

    // MARK: 中央导航（浮起来的胶囊分段条）

    private var tabs: some View {
        HStack(spacing: 2) {
            tab(title: L10n.s("选择台", "Roster"),
                active: onRoster,
                tint: Studio.accent,
                help: L10n.s("回到角色选择台", "Back to the roster"),
                action: onSelectRoster)
            Rectangle().fill(Studio.hairlineStrong.opacity(0.6))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 4)
            ForEach(AppView.Pane.allCases) { pane in
                tab(title: pane.title,
                    active: !onRoster && pane == activePane,
                    tint: WuXingTheme.theme(for: pane).primary,
                    help: "\(WuXingTheme.theme(for: pane).beast) · \(pane.safetyStatement)",
                    action: { onSelectPane(pane) })
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Studio.surface.opacity(0.9)))
        .overlay(Capsule(style: .continuous).strokeBorder(Studio.hairline, lineWidth: 1))
        .shadow(color: Studio.shadowSoft, radius: 10, y: 3)
        .fixedSize()
    }

    /// 选中项是一颗实心胶囊在轨道里滑动（mole.fit 应用里那种分段控件）。
    private func tab(title: String, active: Bool, tint: Color,
                     help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                .foregroundColor(active ? .white : Studio.inkSecondary)
                .padding(.horizontal, 13)
                .frame(height: 26)
                .background {
                    if active {
                        Capsule(style: .continuous)
                            .fill(tint)
                            .matchedGeometryEffect(id: "nav-pill", in: underline)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .help(help)
    }

    // MARK: 右侧读数与开关

    private var trailing: some View {
        HStack(spacing: 10) {
            readout(L10n.s("负载", "CPU"),
                    String(format: "%.0f%%", stat.total),
                    tint: stat.total >= 80 ? Studio.danger : (stat.total >= 50 ? Studio.warning : Studio.success))
            readout(L10n.s("内存", "MEM"),
                    memPercent.map { String(format: "%.0f%%", $0) } ?? "--",
                    tint: (memPercent ?? 0) >= 85 ? Studio.danger : Studio.accent)
            iconButton(isPaused ? "play.fill" : "pause.fill",
                       help: isPaused ? L10n.s("继续刷新", "Resume") : L10n.s("暂停刷新", "Pause"),
                       action: onPause)
            iconButton("gearshape", help: L10n.s("设置", "Settings"), action: onSettings)
        }
        .fixedSize()
    }

    private func readout(_ label: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label.uppercased())
                .font(Studio.microLabel(9))
                .tracking(1.0)
                .foregroundColor(Studio.inkTertiary)
            Text(value)
                .font(Studio.value(12))
                .foregroundColor(Studio.ink)
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(Capsule(style: .continuous).fill(Studio.surface.opacity(0.9)))
        .overlay(Capsule(style: .continuous).strokeBorder(Studio.hairline, lineWidth: 1))
    }

    private func iconButton(_ systemImage: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Studio.inkSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Studio.surface.opacity(0.9)))
                .overlay(Circle().strokeBorder(Studio.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
    }
}
