import AppKit
import SwiftUI

typealias AppViewPane = AppView.Pane

/// 影棚设计系统（Studio）。
///
/// 取自 mole.fit 的质感：暖白纸底 + 深海军蓝墨色 + 衬线标题 + 全圆角胶囊控件。
/// 不用冷灰和直角——那是网页后台的长相；暖白 + 大圆角 + New York 衬线
/// 才是 macOS 原生应用该有的手感。颜色只花在角色立绘和数据上。
enum Studio {

    static func hex(_ v: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255,
              opacity: alpha)
    }

    // MARK: 画布与平面

    /// 暖白背景纸：上浅下深一点点，像影棚里那张无缝纸的自然弯折。
    static let canvasTop = hex(0xFAF8F4)
    static let canvasMid = hex(0xF4F2ED)
    static let canvasBottom = hex(0xEBE7DF)

    static let surface = hex(0xFFFFFF)
    static let surfaceMuted = hex(0xF6F4EF)
    static let surfaceSunken = hex(0xEBE8E1)

    static let hairline = hex(0xE6E2D9)
    static let hairlineStrong = hex(0xD2CCC0)

    // MARK: 文字（海军蓝墨，不是纯黑）

    static let ink = hex(0x1E3556)
    static let inkSecondary = hex(0x5A6678)
    static let inkTertiary = hex(0x9AA1AC)

    // MARK: 强调

    static let accent = hex(0x21406B)
    static let accentPressed = hex(0x17304F)
    static let accentSoft = hex(0xE9EEF6)

    static let danger = hex(0xC0392B)
    static let warning = hex(0xC98A1E)
    static let success = hex(0x1E8A62)

    // MARK: 阴影

    static let shadowSoft = Color.black.opacity(0.06)
    static let shadowLift = Color.black.opacity(0.11)

    // MARK: 圆角（一律往大了给——圆润是这套设计的主要手感）

    static let radiusPanel: CGFloat = 22
    static let radiusCard: CGFloat = 20
    static let radiusSlot: CGFloat = 14
    static let radiusChip: CGFloat = 999      // 胶囊

    // MARK: 字体

    /// 分区微标：全大写 + 大字距，参考里 LOADOUT / SKILL TREE 那一行。
    static func microLabel(_ size: CGFloat = 9.5) -> Font {
        .system(size: size, weight: .semibold)
    }
    static func value(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold).monospacedDigit()
    }
    /// 展示字：走 New York（Apple 的系统衬线），标题和大数字用它才有原生质感。
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// 大数字：衬线 + 等宽数字，读数跳动时不会左右晃。
    static func figure(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif).monospacedDigit()
    }
}

/// 五行主题：金木水火土 + 门，各配一位守护神兽。
/// 行色在亮底上要「站得住」，因此这里的 primary 都是可读色（不是发光色）；
/// secondary / glow 只在立绘辉光与进度条里出现。
enum WuXingTheme {

    struct Theme {
        let element: String        // 行字（金/木/水/火/土/門）
        let beast: String          // 神兽名
        let beastEn: String
        let primary: Color         // 可读行色：圆点 / 细条 / 小标签
        let secondary: Color       // 渐变亮端
        let glow: Color            // 立绘接地辉光
        let soft: Color            // 极淡行色底（选中卡、chip）
        let assetName: String      // Resources 内资源名（fire/metal/...）
        /// 去背立绘（scripts/cutout.swift 从 art/hero-*.jpg 生成），亮底影棚用这张。
        var cutoutName: String { "char-\(assetName)" }
    }

    /// 主题查表：`theme(for:)` 在一次 body 里会被调十几次（顶栏、背景、卡面、底栏…），
    /// 每次都新建 5 个 Color 加一次 L10n.s 拼串。缓存住，只在语言切换时重建。
    private static var cache: [String: Theme] = [:]
    private static var cachedLanguage: String = ""

    static func theme(for pane: AppViewPane) -> Theme {
        let lang = L10n.current.rawValue
        if cachedLanguage != lang {
            cache.removeAll()
            cachedLanguage = lang
        }
        if let hit = cache[pane.rawValue] { return hit }
        let built = build(pane)
        cache[pane.rawValue] = built
        return built
    }

    private static func build(_ pane: AppViewPane) -> Theme {
        switch pane {
        case .status:
            return Theme(element: "火", beast: "朱雀", beastEn: "Vermilion Bird",
                         primary: Studio.hex(0xDD5527),
                         secondary: Studio.hex(0xF6A62A),
                         glow: Studio.hex(0xFF7A3C),
                         soft: Studio.hex(0xFDEEE7),
                         assetName: "fire")
        case .clean:
            return Theme(element: "金", beast: "白虎", beastEn: "White Tiger",
                         primary: Studio.hex(0x9C7F45),
                         secondary: Studio.hex(0xD8C7A8),
                         glow: Studio.hex(0xC9B489),
                         soft: Studio.hex(0xF7F3E9),
                         assetName: "metal")
        case .software:
            return Theme(element: "木", beast: "青龙", beastEn: "Azure Dragon",
                         primary: Studio.hex(0x1B8B6D),
                         secondary: Studio.hex(0x5CD89E),
                         glow: Studio.hex(0x3FBF8C),
                         soft: Studio.hex(0xE6F5F0),
                         assetName: "wood")
        case .optimize:
            return Theme(element: "土", beast: "麒麟", beastEn: "Qilin",
                         primary: Studio.hex(0xAC7A31),
                         secondary: Studio.hex(0xF0C97A),
                         glow: Studio.hex(0xD9A455),
                         soft: Studio.hex(0xFAF2E4),
                         assetName: "earth")
        case .analyze:
            return Theme(element: "水", beast: "玄武", beastEn: "Black Tortoise",
                         primary: Studio.hex(0x2C6DC7),
                         secondary: Studio.hex(0x4FB8E5),
                         glow: Studio.hex(0x4A8FE8),
                         soft: Studio.hex(0xE8F0FC),
                         assetName: "water")
        case .security:
            return Theme(element: "門", beast: "门神", beastEn: "Door Gods",
                         primary: Studio.hex(0xBB3A2E),
                         secondary: Studio.hex(0xF27348),
                         glow: Studio.hex(0xE05A46),
                         soft: Studio.hex(0xFBECE9),
                         assetName: "gate")
        }
    }

}


/// 神兽圆头像：优先用圆形徽章原画（本来就是照圆构图画的），
/// 缺失时退回去背立绘塞进浅色圆底。
struct BeastAvatar: View {
    let theme: WuXingTheme.Theme
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            if let emblem = MythAsset.image(theme.assetName, fitting: size) {
                Image(nsImage: emblem)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else if let cut = MythAsset.image(theme.cutoutName, fitting: size) {
                theme.soft
                Image(nsImage: cut)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.08)
            } else {
                theme.soft
                Text(theme.element)
                    .font(.system(size: size * 0.48, weight: .bold, design: .serif))
                    .foregroundColor(theme.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(theme.primary.opacity(0.30), lineWidth: 1))
    }
}

/// 影棚浮尘：极淡的光点，给亮底一点空气感。
/// 刻意画成静态——每 0.1s 重跑一次 Canvas 只为了让几个点飘起来，
/// 在常驻窗口里换来的是持续的 CPU 占用和肉眼可见的交互延迟。
struct DustOverlay: View {
    let seed: Int
    var count: Int = 26

    var body: some View {
        Canvas { context, size in
            var rng = SplitMix64(state: UInt64(bitPattern: Int64(seed)))
            for _ in 0..<count {
                let x = Double(rng.next() & 0xFFFF) / 65535.0 * size.width
                let y = Double(rng.next() & 0xFFFF) / 65535.0 * size.height
                let r = Double(rng.next() & 0xFF) / 255.0 * 1.5 + 0.8
                let alpha = 0.10 + r * 0.05
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                             with: .color(Studio.hex(0x7A8494, alpha)))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// SplitMix64：确定性伪随机（无需引入第三方）。
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - 基础构件

/// 分区微标：LOADOUT / SKILL TREE 那一行的排版。
struct SectionLabel: View {
    let text: String
    var tint: Color = Studio.inkTertiary

    init(_ text: String, tint: Color = Studio.inkTertiary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(Studio.microLabel())
            .tracking(1.4)
            .foregroundColor(tint)
    }
}

/// 白板：内容承托面。整个界面只有这一种「面」，靠留白而不是描边分区。
struct StudioPanel<Content: View>: View {
    var corner: CGFloat = Studio.radiusPanel
    var padded: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padded ? 14 : 0)
            .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Studio.surface))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Studio.hairline, lineWidth: 1)
            )
            .shadow(color: Studio.shadowSoft, radius: 14, y: 5)
    }
}

/// 主/次按钮：全圆角胶囊，mole.fit 那种「Buy / Download for Mac」的成对关系。
struct StudioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger }
    var kind: Kind = .secondary
    var tint: Color = Studio.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(foreground)
            .padding(.horizontal, kind == .quiet ? 12 : 18)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(background(pressed)))
            .overlay(Capsule(style: .continuous).strokeBorder(border, lineWidth: 1))
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return Studio.ink
        case .quiet: return Studio.inkSecondary
        case .danger: return Studio.danger
        }
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? tint.opacity(0.86) : tint
        case .secondary: return pressed ? Studio.surfaceMuted : Studio.surface
        case .quiet: return pressed ? Studio.surfaceMuted : .clear
        case .danger: return pressed ? Studio.danger.opacity(0.08) : Studio.surface
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return Studio.hairlineStrong
        case .quiet: return .clear
        case .danger: return Studio.danger.opacity(0.4)
        }
    }
}

extension ButtonStyle where Self == StudioButtonStyle {
    static var studioPrimary: StudioButtonStyle { StudioButtonStyle(kind: .primary) }
    static var studioSecondary: StudioButtonStyle { StudioButtonStyle(kind: .secondary) }
    static var studioQuiet: StudioButtonStyle { StudioButtonStyle(kind: .quiet) }
    static var studioDanger: StudioButtonStyle { StudioButtonStyle(kind: .danger) }
    static func studioPrimary(tint: Color) -> StudioButtonStyle {
        StudioButtonStyle(kind: .primary, tint: tint)
    }
}

/// 方形图标槽：参考里 LOADOUT 的四格。圆角跟整体一起放大。
struct SlotButton: View {
    let icon: String
    let title: String
    var tint: Color = Studio.accent
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(enabled ? (hovering ? tint : Studio.inkSecondary) : Studio.inkTertiary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: Studio.radiusSlot, style: .continuous)
                        .fill(hovering && enabled ? tint.opacity(0.10) : Studio.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Studio.radiusSlot, style: .continuous)
                        .strokeBorder(hovering && enabled ? tint.opacity(0.45) : Studio.hairline, lineWidth: 1)
                )
                .shadow(color: Studio.shadowSoft, radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
        .help(title)
    }
}

/// 技能胶囊：一个**真按钮**。点它 = 把这段提示词连同本界上下文交给 AI。
/// 之所以带上文字而不是只留一个圆图标，是因为只有图标的东西看起来像装饰；
/// 能点的就要写清楚点了会发生什么。
struct SkillChip: View {
    let skill: Skill
    var tint: Color = Studio.accent
    let onRun: () -> Void
    /// 内置技能传 nil：没有删除入口。
    var onRemove: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        Button(action: onRun) {
            HStack(spacing: 5) {
                Image(systemName: skill.icon)
                    .font(.system(size: 10.5, weight: .medium))
                Text(skill.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(hovering ? tint : Studio.ink)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule(style: .continuous)
                .fill(hovering ? tint.opacity(0.10) : Studio.surface))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(hovering ? tint.opacity(0.42) : Studio.hairline, lineWidth: 1))
            .shadow(color: Studio.shadowSoft, radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(skill.name)
        .help(skill.detail.isEmpty ? skill.name : "\(skill.name)\n\(skill.detail)")
        .contextMenu {
            if let onRemove {
                Button(L10n.s("移除技能", "Remove skill"), role: .destructive, action: onRemove)
            } else {
                Text(L10n.s("内置技能", "Built-in skill"))
            }
        }
    }
}

/// 大读数卡：状态页顶部那一排。衬线大数字 + 一条弧形进度，
/// 是这套设计里唯一允许「大声说话」的地方。
struct MetricCard: View, Equatable {
    let title: String
    let value: String
    var unit: String = ""
    var caption: String = ""
    var ratio: Double? = nil
    var tint: Color = Studio.accent

    static func == (lhs: MetricCard, rhs: MetricCard) -> Bool {
        lhs.title == rhs.title && lhs.value == rhs.value
            && lhs.unit == rhs.unit && lhs.caption == rhs.caption && lhs.ratio == rhs.ratio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                SectionLabel(title)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Studio.figure(30))
                    .foregroundColor(Studio.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Studio.inkTertiary)
                }
            }
            .padding(.top, 8)

            if let ratio {
                Capsule()
                    .fill(Studio.surfaceSunken)
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            let w = geo.size.width * CGFloat(min(1, max(0, ratio)))
                            if w >= 1 {
                                Capsule().fill(tint).frame(width: max(5, w))
                            }
                        }
                    }
                    .padding(.top, 10)
            }

            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundColor(Studio.inkTertiary)
                    .lineLimit(1)
                    .padding(.top, 7)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Studio.radiusCard, style: .continuous)
            .fill(Studio.surface))
        .overlay(RoundedRectangle(cornerRadius: Studio.radiusCard, style: .continuous)
            .strokeBorder(Studio.hairline, lineWidth: 1))
        .shadow(color: Studio.shadowSoft, radius: 8, y: 3)
    }
}
