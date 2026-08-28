import AppKit
import SwiftUI

// MARK: - 选择台数据契约

/// 卡面属性行：标签 / 数值 / 可选比例（画细条）。值类型 + Equatable，
/// 采样数值没变时整块读数可以按内容跳过重绘。
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

// MARK: - 角色选择台

/// 星轨选择台：六界神兽排在一条椭圆轨道上自己转，没有卡片这层中介。
/// 轨道最前那只放大居中（就是当前选中的界），左右两侧是相邻的两只，
/// 点侧边的兽或按左右键，它就转到中间来。
struct RosterScreen: View {
    @Binding var selection: AppView.Pane
    var statsFor: (AppView.Pane) -> [CardStat] = { _ in [] }
    var loadoutFor: (AppView.Pane) -> [QuickSlot] = { _ in [] }
    var skillsFor: (AppView.Pane) -> [Skill] = { _ in [] }
    var onRunSkill: (Skill) -> Void = { _ in }
    var onRemoveSkill: (Skill) -> Void = { _ in }
    var onImportSkills: ([URL]) -> Void = { _ in }
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
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.78)
    }

    var body: some View {
        GeometryReader { geo in
            let railH: CGFloat = 96
            let plateH: CGFloat = 108
            let orbitH = max(220, geo.size.height - railH - plateH - 10)
            VStack(spacing: 0) {
                orbitStage(width: geo.size.width, height: orbitH)
                    .frame(width: geo.size.width, height: orbitH)
                nameplate
                    .frame(height: plateH)
                Spacer(minLength: 0)
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

    // MARK: 星轨

    private func orbitStage(width: CGFloat, height: CGFloat) -> some View {
        let ry = height * 0.085
        let rx = min(width * 0.32, 460)
        let frontSize = min(height * 0.86, width * 0.42)
        let baseline = height * 0.5 - frontSize * 0.5 + frontSize * 0.42

        return ZStack {
            OrbitRing(theme: theme, rx: rx, ry: ry, animated: !reduceMotion)
                .offset(y: baseline + ry * 0.2)

            ForEach(Array(panes.enumerated()), id: \.offset) { i, pane in
                orbitBeast(pane, index: i, frontSize: frontSize,
                           rx: rx, ry: ry, baseline: baseline)
            }

            HStack {
                arrowButton(-1)
                Spacer(minLength: 0)
                arrowButton(1)
            }
            .padding(.horizontal, max(6, width * 0.5 - rx - frontSize * 0.30))
            .offset(y: baseline * 0.35)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(orbitDrag(slotWidth: max(90, rx * 0.6)))
        .hideFocusRing()
    }

    /// 轨道角：选中项落在正下方（θ=π/2），也就是离镜头最近的那一点。
    private func orbitAngle(_ index: Int) -> Double {
        let n = Double(count)
        return (Double(index) - focus) / n * 2 * .pi + .pi / 2
    }

    private func orbitBeast(_ pane: AppView.Pane, index: Int, frontSize: CGFloat,
                            rx: CGFloat, ry: CGFloat, baseline: CGFloat) -> some View {
        let t = WuXingTheme.theme(for: pane)
        let theta = orbitAngle(index)
        let depth = sin(theta)                       // +1 最前，-1 最后
        let d = (depth + 1) / 2
        let isFront = depth > 0.9
        // 前后差距拉得很开：最前那只是主角，最后那只只是轨道上的一个影子。
        let size = frontSize * (0.30 + 0.70 * pow(d, 1.6))
        let opacity = 0.16 + 0.84 * pow(d, 1.9)
        let blur = (1 - d) * 3.5                     // 景深：越靠后越虚

        return BeastFigure(theme: t, size: size, isFront: isFront,
                           animated: !reduceMotion)
            .blur(radius: blur)
            .opacity(opacity)
            .offset(x: CGFloat(cos(theta)) * rx,
                    y: baseline + CGFloat(sin(theta)) * ry - size * 0.5)
            .zIndex(depth + 2)
            .contentShape(Rectangle())
            .onTapGesture { isFront ? onEnter() : select(pane) }
            .help(isFront
                  ? L10n.s("进入「\(pane.title)」", "Enter “\(pane.title)”")
                  : "\(t.beast) · \(pane.title)")
    }

    private func arrowButton(_ dir: Int) -> some View {
        Button { cycle(dir) } label: {
            Image(systemName: dir < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Studio.inkSecondary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Studio.surface))
                .overlay(Circle().strokeBorder(Studio.hairline, lineWidth: 1))
                .shadow(color: Studio.shadowSoft, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dir < 0 ? L10n.s("上一界", "Previous realm")
                                    : L10n.s("下一界", "Next realm"))
        .help(dir < 0 ? L10n.s("上一界", "Previous realm") : L10n.s("下一界", "Next realm"))
    }

    // MARK: 铭牌（卡片上那些字现在长在这儿）

    private var nameplate: some View {
        let stats = statsFor(selection)
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(theme.beast)
                    .font(Studio.display(30, weight: .semibold))
                    .foregroundColor(Studio.ink)
                Text("\(theme.element) · \(selection.title)")
                    .font(Studio.microLabel(10))
                    .tracking(1.6)
                    .foregroundColor(theme.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.soft))
            }
            HStack(spacing: 0) {
                ForEach(Array(stats.prefix(4).enumerated()), id: \.element.id) { i, row in
                    if i > 0 {
                        Rectangle().fill(Studio.hairline)
                            .frame(width: 1, height: 22)
                            .padding(.horizontal, 16)
                    }
                    VStack(spacing: 2) {
                        Text(row.label.uppercased())
                            .font(Studio.microLabel(9))
                            .tracking(1.1)
                            .foregroundColor(Studio.inkTertiary)
                        Text(row.value)
                            .font(Studio.figure(17))
                            .foregroundColor(Studio.ink)
                    }
                    .frame(minWidth: 62)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selection)
    }

    // MARK: 底部三段栏

    private var bottomRail: some View {
        let slots = loadoutFor(selection)
        return StudioPanel {
            HStack(alignment: .center, spacing: 18) {
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
                .fixedSize()

                railDivider

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SectionLabel(L10n.s("技能 · SKILLS", "SKILLS"))
                        Text(L10n.s("点一下就把这件事交给 AI", "One click hands it to the AI"))
                            .font(.system(size: 9))
                            .foregroundColor(Studio.inkTertiary.opacity(0.8))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(skillsFor(selection)) { skill in
                                SkillChip(skill: skill, tint: theme.primary,
                                          onRun: { onRunSkill(skill) },
                                          onRemove: skill.builtIn ? nil : { onRemoveSkill(skill) })
                            }
                            importChip
                        }
                        .padding(.vertical, 1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 9) {
                    Text(selection.safetyStatement)
                        .font(.system(size: 10))
                        .foregroundColor(Studio.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 8) {
                        Button(L10n.s("进入", "Enter")) { onEnter() }
                            .buttonStyle(.studioPrimary(tint: theme.primary))
                            .keyboardShortcut(.defaultAction)
                            .help(L10n.s("进入「\(selection.title)」工作台", "Open the \(selection.title) workspace"))
                        Button(analyzeTitle.isEmpty ? L10n.s("AI 分析", "Analyze") : analyzeTitle) { onAnalyze() }
                            .buttonStyle(.studioSecondary)
                            .disabled(analyzeDisabled)
                        Button(L10n.s("设置", "Settings")) { onSettings() }
                            .buttonStyle(.studioSecondary)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    /// 导入技能：走系统文件面板，只收 .json。
    private var importChip: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.prompt = L10n.s("导入", "Import")
            panel.message = L10n.s("选择技能文件（.json）。技能只是一段提示词，导入后不会自动执行任何操作。",
                                   "Pick skill files (.json). A skill is just a prompt — importing never runs anything.")
            if panel.runModal() == .OK { onImportSkills(panel.urls) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.s("导入", "Import"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Studio.inkSecondary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule(style: .continuous).fill(Studio.surfaceMuted))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(Studio.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.s("导入技能", "Import skills"))
        .help(L10n.s("导入 .json 技能文件；技能只是提示词，不会自动执行任何操作",
                     "Import .json skills; a skill is only a prompt and never runs anything by itself"))
    }

    private var railDivider: some View {
        Rectangle().fill(Studio.hairline).frame(width: 1, height: 46)
    }

    // MARK: 转轨

    private func orbitDrag(slotWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = focus }
                focus = (dragOrigin ?? 0) - Double(value.translation.width / slotWidth)
            }
            .onEnded { value in
                let origin = dragOrigin ?? focus
                dragOrigin = nil
                snap(to: origin - Double(value.predictedEndTranslation.width / slotWidth))
            }
    }

    private func cycle(_ dir: Int) {
        var i = Int(focus.rounded()) + dir
        i = ((i % count) + count) % count
        select(panes[i])
    }

    private func select(_ pane: AppView.Pane) {
        rotate(to: pane, commit: true)
    }

    /// 转到目标界：沿「绕一圈里最短的那条路」走，不会为了到隔壁而绕远。
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
        var idx = Int(projected.rounded()) % count
        if idx < 0 { idx += count }
        select(panes[idx])
    }
}

// MARK: - 轨道环

/// 星系感的来源：一圈静止的细椭圆 + 一圈缓慢自转的虚线椭圆。
/// 自转走隐式动画（GPU 插值），不逐帧重跑 body。
struct OrbitRing: View {
    let theme: WuXingTheme.Theme
    let rx: CGFloat
    let ry: CGFloat
    var animated: Bool = true
    @State private var spin = false

    var body: some View {
        ZStack {
            Ellipse()
                .strokeBorder(Studio.hairlineStrong.opacity(0.42), lineWidth: 1)
                .frame(width: rx * 2, height: ry * 2)
            Ellipse()
                .strokeBorder(theme.primary.opacity(0.22),
                              style: StrokeStyle(lineWidth: 1, dash: [2, 14]))
                .frame(width: rx * 2, height: ry * 2)
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .allowsHitTesting(false)
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: 48).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
    }
}

// MARK: - 轨道上的一只神兽

/// 立绘本体 + 光环 + 接地投影 + 倒影。只有最前那只开全套特效，
/// 后面的都是缩小压暗的剪影——不然六套辉光叠在一起就是一片糊。
struct BeastFigure: View {
    let theme: WuXingTheme.Theme
    let size: CGFloat
    var isFront: Bool = false
    var animated: Bool = true

    @State private var idle = false
    @State private var pulse = false

    var body: some View {
        let img = MythAsset.image(theme.cutoutName, fitting: size)
            ?? MythAsset.image(theme.assetName, fitting: size)
        return ZStack {
            if isFront {
                aura
            }
            VStack(spacing: 0) {
                Group {
                    if let img {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.medium)
                            .scaledToFit()
                            .shadow(color: theme.glow.opacity(isFront ? 0.32 : 0.12),
                                    radius: isFront ? 30 : 10, y: 8)
                    }
                }
                .frame(width: size, height: size * 0.80)

                ZStack(alignment: .top) {
                    contactShadow
                    if isFront, let img { reflection(img) }
                }
                .frame(height: size * 0.20)
            }
            .drawingGroup()             // 立绘+辉光+倒影栅格化一次，转轨时纯 GPU 合成
            .offset(y: idle ? 3 : -3)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                idle = true
            }
            if isFront {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }

    /// 行色光环：主角脚下那圈呼吸的光，是「这只被选中了」最直接的信号。
    private var aura: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [theme.glow.opacity(0.20), .clear],
                                     center: .center,
                                     startRadius: size * 0.06,
                                     endRadius: size * 0.52))
                .scaleEffect(pulse ? 1.06 : 0.94)
            Circle()
                .strokeBorder(theme.primary.opacity(0.16), lineWidth: 1)
                .frame(width: size * 0.86, height: size * 0.86)
                .scaleEffect(pulse ? 1.04 : 0.98)
        }
        .allowsHitTesting(false)
    }

    private var contactShadow: some View {
        Ellipse()
            .fill(RadialGradient(colors: [Studio.hex(0x2B3240, isFront ? 0.26 : 0.14), .clear],
                                 center: .center, startRadius: 0, endRadius: size * 0.24))
            .frame(width: size * 0.56, height: size * 0.10)
            .blur(radius: 6)
            .offset(y: -size * 0.03)
            .allowsHitTesting(false)
    }

    private func reflection(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .interpolation(.medium)
            .scaledToFit()
            .scaleEffect(x: 1, y: -1)
            .frame(width: size, height: size * 0.20)
            .opacity(0.15)
            .blur(radius: 1.2)
            .mask(LinearGradient(colors: [Color.white.opacity(0.75), .clear],
                                 startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
    }
}
