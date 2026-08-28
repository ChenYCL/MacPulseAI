import AppKit
import SwiftUI

// MARK: - 选择台数据契约

/// 卡面属性行：标签 / 数值 / 可选比例（画细条）。值类型 + Equatable，
/// 采样数值没变时整套卡牌可以按内容跳过重绘。
struct CardStat: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let value: String
    var ratio: Double? = nil
}

/// 装备槽：本模块的一个快捷动作。
struct QuickSlot: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    var enabled: Bool = true
    let action: () -> Void
}

/// 能力点：本模块具备的能力/约束，只做说明不可点。
struct SkillSpec: Identifiable, Equatable {
    let id = UUID()
    let icon: String
    let title: String
    var active: Bool = true
}

// MARK: - 角色选择台

/// 影棚式角色选择：左封面流卡牌，右去背立绘，底部装备/能力/操作三段栏。
/// 版式语法照抄游戏角色选择台——干净背景纸、克制的排版、只有一枚强调色。
struct RosterScreen: View {
    @Binding var selection: AppView.Pane
    var statsFor: (AppView.Pane) -> [CardStat] = { _ in [] }
    var loadoutFor: (AppView.Pane) -> [QuickSlot] = { _ in [] }
    var skillsFor: (AppView.Pane) -> [SkillSpec] = { _ in [] }
    var onEnter: () -> Void = {}
    var onAnalyze: () -> Void = {}
    var onSettings: () -> Void = {}
    var analyzeTitle: String = ""
    var analyzeDisabled: Bool = false

    @State private var focus: Double = 0
    @State private var dragOrigin: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panes: [AppView.Pane] { Array(AppView.Pane.allCases) }
    private var count: Int { panes.count }
    private var theme: WuXingTheme.Theme { WuXingTheme.theme(for: selection) }

    private var spring: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.85)
    }

    var body: some View {
        GeometryReader { geo in
            let railH: CGFloat = 90
            let gap: CGFloat = 14
            let stageH = max(210, geo.size.height - railH - gap)
            // 卡组固定占左侧四成：GeometryReader 没有固有尺寸，
            // 交给 HStack 自己分会被同样弹性的立绘台吃光。
            let cardsW = min(560, max(320, geo.size.width * 0.44))
            VStack(spacing: gap) {
                HStack(alignment: .bottom, spacing: 4) {
                    coverFlow(width: cardsW, height: stageH)
                        .frame(width: cardsW, height: stageH)
                    HeroStage(theme: theme)
                        .frame(maxWidth: .infinity)
                        .frame(height: stageH)
                }
                bottomRail
                    .frame(height: railH)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .onAppear {
            if let i = panes.firstIndex(of: selection) { focus = Double(i) }
        }
        .onChange(of: selection) { newValue in
            rotate(to: newValue, commit: false)
        }
    }

    // MARK: 封面流

    private func coverFlow(width: CGFloat, height: CGFloat) -> some View {
        // 卡面按参考稿的比例走：高度吃满台面，宽高比约 0.60，
        // 相邻卡露出 ~70% —— 侧卡的名字和数值要能读，不能只剩一条边。
        let cardH = min(420, max(210, height * 0.86))
        let cardW = min(width * 0.42, cardH * 0.62)
        let slot = cardW * 0.70
        return ZStack(alignment: .bottom) {
            ForEach(Array(panes.enumerated()), id: \.offset) { i, pane in
                flowingCard(pane, index: i, cardW: cardW, cardH: cardH, slot: slot)
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
        .offset(y: -height * 0.04)
        .contentShape(Rectangle())
        .gesture(flowDrag(slotWidth: max(64, slot)))
        // 边缘只做一小截柔化：卡组像被画布裁切，而不是整体发虚。
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .white, location: 0.05),
                .init(color: .white, location: 0.95),
                .init(color: .clear, location: 1.00)
            ], startPoint: .leading, endPoint: .trailing)
        )
        .hideFocusRing()
    }

    /// 环形封面流：卡牌两侧都要有邻居，所以位移取「绕一圈里最短的那条路」。
    /// n=6 时 delta ∈ [-3, 3]，越界的那一张在 |delta|>2.9 处已经淡到全透明，
    /// 于是 +3 ↔ -3 的瞬移永远发生在看不见的时候。
    private func wrappedDelta(_ index: Int) -> Double {
        let n = Double(count)
        var d = (Double(index) - focus).truncatingRemainder(dividingBy: n)
        if d > n / 2 { d -= n }
        if d < -n / 2 { d += n }
        return d
    }

    private func flowingCard(_ pane: AppView.Pane, index: Int,
                             cardW: CGFloat, cardH: CGFloat, slot: CGFloat) -> some View {
        let delta = CGFloat(wrappedDelta(index))
        let absD = abs(delta)
        let isFront = absD < 0.45
        let fade = min(1, max(0, (2.9 - Double(absD)) / 0.7))
        // 转角在第一张邻居处就到顶：再往外继续转会把卡片压成一条边，
        // 参考稿里的侧卡始终是能认出脸和名字的。
        let turn = Double(max(-1.0, min(1.0, delta / 1.15))) * -24
        return RosterCard(theme: WuXingTheme.theme(for: pane),
                          paneTitle: pane.title,
                          stats: statsFor(pane),
                          selected: isFront,
                          portraitHeight: cardH * 0.52)
            .equatable()                                  // 转卡时只动变换，不重建卡面
            .frame(width: cardW, height: cardH)
            .rotation3DEffect(reduceMotion ? .zero : .degrees(turn),
                              axis: (x: 0, y: 1, z: 0),
                              anchor: delta < 0 ? .trailing : .leading,
                              perspective: 0.38)
            .scaleEffect(isFront ? 1.0 : max(0.82, 0.92 - absD * 0.04), anchor: .bottom)
            .offset(x: delta * slot, y: isFront ? -18 : 0)
            .brightness(isFront ? 0 : -0.015)
            .opacity(fade)
            .zIndex(20 - Double(absD))
            .contentShape(Rectangle())
            .onTapGesture { isFront ? onEnter() : select(pane) }
            .help(isFront
                  ? L10n.s("进入「\(pane.title)」", "Enter “\(pane.title)”")
                  : "\(WuXingTheme.theme(for: pane).beast) · \(pane.title)")
    }

    private func flowDrag(slotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = focus }
                focus = (dragOrigin ?? 0) - Double(value.translation.width / slotWidth)
            }
            .onEnded { value in
                let origin = dragOrigin ?? focus
                dragOrigin = nil
                let projected = origin - Double(value.predictedEndTranslation.width / slotWidth)
                snap(to: projected)
            }
    }

    // MARK: 底部三段栏

    private var bottomRail: some View {
        let slots = loadoutFor(selection)
        let skills = skillsFor(selection)
        return StudioPanel {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(L10n.s("装备 · LOADOUT", "LOADOUT"))
                    HStack(spacing: 8) {
                        ForEach(slots) { slot in
                            SlotButton(icon: slot.icon, title: slot.title,
                                       tint: theme.primary, enabled: slot.enabled,
                                       action: slot.action)
                        }
                    }
                }

                railDivider

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(L10n.s("能力 · SKILLS", "SKILLS"))
                    HStack(spacing: 8) {
                        ForEach(skills) { skill in
                            SkillDot(icon: skill.icon, title: skill.title,
                                     tint: theme.primary, active: skill.active)
                        }
                    }
                    .frame(height: 36)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 9) {
                    Text(selection.safetyStatement)
                        .font(.system(size: 10))
                        .foregroundColor(Studio.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 8) {
                        Button(L10n.s("进入", "SELECT")) { onEnter() }
                            .buttonStyle(.studioPrimary(tint: theme.primary))
                            .keyboardShortcut(.defaultAction)
                            .help(L10n.s("进入「\(selection.title)」工作台", "Open the \(selection.title) workspace"))
                        Button(analyzeTitle.isEmpty ? L10n.s("AI 分析", "ANALYZE") : analyzeTitle) { onAnalyze() }
                            .buttonStyle(.studioSecondary)
                            .disabled(analyzeDisabled)
                        Button(L10n.s("设置", "SETTINGS")) { onSettings() }
                            .buttonStyle(.studioSecondary)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
    }

    private var railDivider: some View {
        Rectangle().fill(Studio.hairline).frame(width: 1, height: 46)
    }

    // MARK: 选择逻辑

    private func select(_ pane: AppView.Pane) {
        rotate(to: pane, commit: true)
    }

    private func rotate(to pane: AppView.Pane, commit: Bool) {
        guard let idx = panes.firstIndex(of: pane) else { return }
        let n = Double(count)
        var currentMod = focus.truncatingRemainder(dividingBy: n)
        if currentMod < 0 { currentMod += n }
        var delta = Double(idx) - currentMod
        if delta > n / 2 { delta -= n }
        if delta < -n / 2 { delta += n }
        if commit {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { selection = pane }
        }
        guard abs(delta) > 0.001 else { return }
        withAnimation(spring) { focus += delta }
    }

    private func snap(to projected: Double) {
        let nearest = projected.rounded()
        var idx = Int(nearest) % count
        if idx < 0 { idx += count }
        select(panes[idx])
    }
}

// MARK: - 单张角色卡

/// 白卡：上半身立绘 + 名 + 界别 + 属性行。选中卡抬起并压一条行色。
/// Equatable：采样数值没变时整套卡面跳过重绘（监控 2s 一刷不再打穿卡组）。
struct RosterCard: View, Equatable {
    let theme: WuXingTheme.Theme
    let paneTitle: String
    let stats: [CardStat]
    var selected: Bool = false
    var portraitHeight: CGFloat = 116

    static func == (lhs: RosterCard, rhs: RosterCard) -> Bool {
        lhs.theme.assetName == rhs.theme.assetName      // assetName 唯一标识一界
            && lhs.selected == rhs.selected
            && lhs.paneTitle == rhs.paneTitle
            && lhs.portraitHeight == rhs.portraitHeight
            && lhs.stats == rhs.stats
    }

    var body: some View {
        VStack(spacing: 0) {
            if selected {
                Rectangle().fill(theme.primary).frame(height: 3)
            }
            portrait
            VStack(alignment: .leading, spacing: 3) {
                Text(theme.beast)
                    .font(Studio.display(19, weight: .semibold))
                    .foregroundColor(Studio.ink)
                    .lineLimit(1)
                Text("\(theme.element) · \(paneTitle)")
                    .font(Studio.microLabel(9))
                    .tracking(1.2)
                    .foregroundColor(theme.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 11)

            Spacer(minLength: 8)

            // 属性行贴着卡底排：参考稿里名字紧跟头像，数值压在最下面。
            VStack(spacing: 7) {
                Rectangle().fill(Studio.hairline).frame(height: 1)
                ForEach(stats.prefix(4)) { row in
                    StatReadout(label: row.label, value: row.value,
                                ratio: row.ratio, tint: theme.primary, compact: true)
                        .equatable()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 15)
        }
        // 卡面是「立在影棚地上的展板」，不是贴上去的白方块。
        // 融进场景靠的是柔和的描边和接地投影，而不是半透明——
        // 卡牌本来就相互叠着，透一点就会把后面那张的名字漏到前面这张的属性行上。
        .background(RoundedRectangle(cornerRadius: Studio.radiusCard, style: .continuous)
            .fill(selected ? Studio.surface : Studio.canvasTop))
        .clipShape(RoundedRectangle(cornerRadius: Studio.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Studio.radiusCard, style: .continuous)
                .strokeBorder(selected ? theme.primary.opacity(0.30) : Studio.hairline,
                              lineWidth: 1)
        )
        .shadow(color: Studio.hex(0x2B3240, selected ? 0.15 : 0.08),
                radius: selected ? 30 : 16,
                y: selected ? 16 : 9)
        .compositingGroup()
    }

    /// 头像位：浅色底盘 + 去背立绘，绝不做成一张贴了边的方形照片。
    private var portrait: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [theme.soft, Studio.surfaceMuted.opacity(0.5)],
                                     startPoint: .top, endPoint: .bottom))
            // 缩放副本：原图接近 900px，卡面只有 ~180pt，直接喂原图会在每个动画帧重采样。
            if let img = MythAsset.image(theme.cutoutName, fitting: portraitHeight)
                ?? MythAsset.image(theme.assetName, fitting: portraitHeight) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .padding(8)
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 3)
            }
        }
        .frame(height: portraitHeight)
        .drawingGroup()                                  // 立绘+投影只栅格化一次，转卡时复用
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

// MARK: - 英雄台

/// 右侧英雄台：巨大行字水印 + 去背立绘 + 接地投影 + 地面倒影，idle 轻微起伏。
///
/// idle 动画走隐式动画（repeatForever）而不是 TimelineView：
/// TimelineView 会按帧重跑整个 body——立绘、辉光、倒影、投影全部重新求值，
/// 常驻窗口里这就是十几个百分点的 CPU。改成隐式动画后每帧变化的只有
/// offset / rotation 两个可动画属性，由渲染服务在 GPU 上插值，body 一次都不重跑。
struct HeroStage: View {
    let theme: WuXingTheme.Theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var idle = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                watermark(height: h)
                figure(size: geo.size)
                    .offset(y: idle ? 3 : -3)
                    .rotation3DEffect(.degrees(idle ? 3.5 : -3.5),
                                      axis: (x: 0.06, y: 1, z: 0), perspective: 0.5)
            }
            .frame(width: geo.size.width, height: h)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                idle = true
            }
        }
        .hideFocusRing()
    }

    /// 行字水印：极淡的一个大字，给画面一个重心又不抢立绘。
    private func watermark(height: CGFloat) -> some View {
        Text(theme.element)
            .font(.system(size: max(120, height * 0.66), weight: .black, design: .serif))
            .foregroundColor(Studio.hex(0x2A3340, 0.045))
            .offset(y: -height * 0.10)
            .allowsHitTesting(false)
    }

    private func figure(size: CGSize) -> some View {
        let heroH = size.height * 0.78
        // 缩放副本：原图接近 900px，直接喂原图会在每次重绘时重采样。
        let img = MythAsset.image(theme.cutoutName, fitting: heroH)
            ?? MythAsset.image(theme.assetName, fitting: heroH)
        let reflectH = size.height * 0.13
        let bottomPad = size.height * 0.05

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if let img {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .shadow(color: theme.glow.opacity(0.22), radius: 26, y: 10)
                }
            }
            .frame(maxWidth: size.width * 0.76, maxHeight: heroH)

            ZStack(alignment: .top) {
                contactShadow(width: size.width)
                    .offset(y: -7)
                reflection(img)
            }
            .frame(height: reflectH)
        }
        .padding(.bottom, bottomPad)
        .padding(.horizontal, 10)
        // 立绘 + 辉光 + 倒影 + 投影栅格化成一张位图，随后的位移/旋转纯 GPU 合成。
        .drawingGroup()
    }

    /// 接地投影：立绘脚下那团压得住的暗，是「站在地上」而不是「浮着」的关键。
    private func contactShadow(width: CGFloat) -> some View {
        Ellipse()
            .fill(RadialGradient(colors: [Studio.hex(0x2B3240, 0.28), .clear],
                                 center: .center, startRadius: 0, endRadius: width * 0.22))
            .frame(width: width * 0.52, height: 22)
            .blur(radius: 7)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func reflection(_ img: NSImage?) -> some View {
        if let img {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(x: 1, y: -1)
                .opacity(0.16)
                .blur(radius: 1.2)
                .mask(
                    LinearGradient(colors: [Color.white.opacity(0.7), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
                .allowsHitTesting(false)
        }
    }
}
