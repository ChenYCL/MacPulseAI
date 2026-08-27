import SwiftUI

/// 顶栏统计区（Equatable）：监控数值不变时跳过重绘，显著降低常驻刷新的布局开销。
/// 数值稳定到 0.1 再比较——亚 0.1% 的抖动只会制造 UI diff，没有信息量。
struct StatValue: Equatable {
    let user: Double, sys: Double, idle: Double
    init(_ l: SystemLoad) {
        user = (l.userPercent * 10).rounded() / 10
        sys = (l.systemPercent * 10).rounded() / 10
        idle = (l.idlePercent * 10).rounded() / 10
    }
}

struct HeaderView: View, Equatable {
    let stat: StatValue
    let memPercent: Double?
    let swapText: String?
    let isPaused: Bool
    let analyzeTitle: String
    let analyzeHelp: String
    let analyzeDisabled: Bool
    @Binding var refreshInterval: Double
    let onAnalyze: () -> Void
    let onPause: () -> Void
    let onSettings: () -> Void

    init(load: SystemLoad, memPercent: Double?, swapText: String?,
         isPaused: Bool, analyzeTitle: String, analyzeHelp: String, analyzeDisabled: Bool,
         refreshInterval: Binding<Double>,
         onAnalyze: @escaping () -> Void,
         onPause: @escaping () -> Void,
         onSettings: @escaping () -> Void) {
        self.stat = StatValue(load)
        self.memPercent = memPercent.map { ($0 * 10).rounded() / 10 }
        self.swapText = swapText
        self.isPaused = isPaused
        self.analyzeTitle = analyzeTitle
        self.analyzeHelp = analyzeHelp
        self.analyzeDisabled = analyzeDisabled
        self._refreshInterval = refreshInterval
        self.onAnalyze = onAnalyze
        self.onPause = onPause
        self.onSettings = onSettings
    }

    static func == (lhs: HeaderView, rhs: HeaderView) -> Bool {
        lhs.stat == rhs.stat && lhs.memPercent == rhs.memPercent
            && lhs.swapText == rhs.swapText && lhs.isPaused == rhs.isPaused
            && lhs.analyzeTitle == rhs.analyzeTitle && lhs.analyzeDisabled == rhs.analyzeDisabled
            && lhs.refreshInterval == rhs.refreshInterval
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.heart.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(LinearGradient(colors: [.pink, .purple],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                VStack(alignment: .leading, spacing: 0) {
                    Text("MacPulse AI").font(.headline)
                    Text(L10n.s("AI 进程管家", "AI Process Manager"))
                        .font(.system(size: 9)).foregroundColor(.secondary)
                }
            }

            HStack(spacing: 6) {
                statCard(L10n.s("用户", "USER"), value: String(format: "%.1f%%", stat.user),
                         icon: "person.fill", tint: .blue)
                statCard(L10n.s("系统", "SYS"), value: String(format: "%.1f%%", stat.sys),
                         icon: "gearshape.fill", tint: .orange)
                statCard(L10n.s("空闲", "IDLE"), value: String(format: "%.1f%%", stat.idle),
                         icon: "zzz", tint: .green)
                statCard(L10n.s("内存", "MEM"),
                         value: memPercent.map { String(format: "%.1f%%", $0) } ?? "--",
                         icon: "memorychip", tint: .indigo, warn: (memPercent ?? 0) >= 85)
                if let swap = swapText {
                    statCard(L10n.s("交换", "SWAP"), value: swap,
                             icon: "arrow.triangle.swap", tint: .red, warn: true)
                }
            }

            Spacer(minLength: 8)

            Button(action: onAnalyze) {
                Label(analyzeTitle, systemImage: "sparkles")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .shadow(color: .purple.opacity(0.30), radius: 5, y: 2)
            .disabled(analyzeDisabled)
            .help(analyzeHelp)

            Picker(L10n.s("刷新", "Refresh"), selection: $refreshInterval) {
                ForEach([1.0, 2.0, 5.0], id: \.self) { v in
                    Text(L10n.s(String(format: "%.0f 秒", v), String(format: "%.0fs", v))).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 172)

            HStack(spacing: 4) {
                iconHeaderButton(isPaused ? "play.fill" : "pause.fill",
                                 help: isPaused ? L10n.s("继续刷新", "Resume") : L10n.s("暂停刷新", "Pause"),
                                 action: onPause)
                iconHeaderButton("gearshape", help: L10n.s("设置", "Settings"), action: onSettings)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func iconHeaderButton(_ systemImage: String, help: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 26)
        }
        .buttonStyle(.bordered)
        .help(help)
    }

    private func statCard(_ title: String, value: String, icon: String,
                          tint: Color, warn: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tint.opacity(warn ? 0.9 : 0.75)))
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(warn ? tint : .primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06)))
    }
}
