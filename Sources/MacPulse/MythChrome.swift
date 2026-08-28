import AppKit
import SwiftUI

extension Notification.Name {
    /// 菜单栏 HUD / 外部入口要求主窗口切到某一页。object 为 `AppView.Pane.rawValue`。
    static let macPulseRevealPane = Notification.Name("MacPulseRevealPane")
}

/// 从 .app Resources 或 SPM bundle 加载五行原画。结果按名缓存，避免重复解码。
enum MythAsset {
    private static let lock = NSLock()
    private static var cache: [String: NSImage] = [:]
    private static var scaledCache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func image(_ name: String) -> NSImage? {
        lock.lock()
        if let img = cache[name] { lock.unlock(); return img }
        if misses.contains(name) { lock.unlock(); return nil }
        lock.unlock()

        let loaded = loadUncached(name)
        lock.lock()
        if let loaded {
            cache[name] = loaded
        } else {
            misses.insert(name)
        }
        lock.unlock()
        return loaded
    }

    /// 按显示尺寸取一份降采样副本。
    /// 立绘原图接近 900px，卡面只有 180pt——每帧把原图重采样一次是选择台卡顿的主因，
    /// 这里按 128pt 一档做桶缓存，同一档只解码缩放一次。
    static func image(_ name: String, fitting points: CGFloat) -> NSImage? {
        guard let base = image(name) else { return nil }
        let bucket = max(128, (ceil(points / 128) * 128))
        let target = bucket * 2                       // Retina
        guard max(base.size.width, base.size.height) > target else { return base }

        let key = "\(name)@\(Int(bucket))"
        lock.lock()
        if let hit = scaledCache[key] { lock.unlock(); return hit }
        lock.unlock()

        let scale = target / max(base.size.width, base.size.height)
        let size = NSSize(width: (base.size.width * scale).rounded(),
                          height: (base.size.height * scale).rounded())
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        base.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: base.size),
                  operation: .copy, fraction: 1)
        out.unlockFocus()

        lock.lock()
        scaledCache[key] = out
        lock.unlock()
        return out
    }

    private static func loadUncached(_ name: String) -> NSImage? {
        if let img = NSImage(named: name) { return img }
        let exts = ["png", "jpg", "jpeg"]
        var urls: [URL] = []
        if let root = Bundle.main.resourceURL {
            for ext in exts {
                urls.append(root.appendingPathComponent("\(name).\(ext)"))
                urls.append(root.appendingPathComponent("Resources/\(name).\(ext)"))
            }
        }
        #if SWIFT_PACKAGE
        for ext in exts {
            if let u = Bundle.module.url(forResource: name, withExtension: ext) { urls.append(u) }
            if let u = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") {
                urls.append(u)
            }
        }
        #endif
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            if let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }

    static func template(_ name: String, pointSize: CGFloat) -> NSImage? {
        guard let base = image(name) else { return nil }
        let size = NSSize(width: pointSize, height: pointSize)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        base.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: base.size),
                  operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}

/// 影棚背景：无缝背景纸 + 一层极淡的实时遥测。
///
/// 遥测层画的是真数据（负载波形、内存环、进程密度），但刻意压到看不太清——
/// 它是气氛，不是仪表盘；真要读数值有顶栏和状态页。所以这里没有任何标签和刻度，
/// 只有「这台机器现在在动」这一个信息。
struct StudioBackdrop: View {
    let theme: WuXingTheme.Theme
    /// 负载历史（0–100），最后一个是最新。
    var loadHistory: [Double] = []
    var memoryRatio: Double? = nil
    var processCount: Int = 0
    /// 柔光中心（单位坐标），角色站哪儿光就打哪儿。
    var lightCenter: UnitPoint = UnitPoint(x: 0.5, y: 0.40)
    var dust: Bool = true

    var body: some View {
        GeometryReader { geo in
            let d = max(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: Studio.canvasTop, location: 0.00),
                        .init(color: Studio.canvasMid, location: 0.55),
                        .init(color: Studio.canvasBottom, location: 1.00)
                    ],
                    startPoint: .top, endPoint: .bottom)

                // 主光：略带当前行色，让六界各有体温又不至于花。
                RadialGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.85), location: 0.0),
                        .init(color: theme.soft.opacity(0.55), location: 0.45),
                        .init(color: .clear, location: 1.0)
                    ],
                    center: lightCenter, startRadius: 0, endRadius: d * 0.55)

                TelemetryLayer(theme: theme,
                               history: loadHistory,
                               memoryRatio: memoryRatio,
                               processCount: processCount)

                // 暗角：把视线收回画面中央。
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.55),
                        .init(color: Studio.hex(0x5B6472, 0.10), location: 1.0)
                    ],
                    center: .center, startRadius: 0, endRadius: d * 0.72)

                if dust {
                    DustOverlay(seed: theme.assetName.hashValue, count: 22)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 实时遥测底纹：底部负载波形 + 中心内存环 + 按进程数疏密的刻度点。
/// 整层用一个 Canvas 画完，2 秒一拍随数据重绘，不做逐帧动画。
struct TelemetryLayer: View, Equatable {
    let theme: WuXingTheme.Theme
    let history: [Double]
    let memoryRatio: Double?
    let processCount: Int

    static func == (lhs: TelemetryLayer, rhs: TelemetryLayer) -> Bool {
        lhs.theme.assetName == rhs.theme.assetName
            && lhs.history == rhs.history
            && lhs.memoryRatio == rhs.memoryRatio
            && lhs.processCount == rhs.processCount
    }

    var body: some View {
        Canvas { ctx, size in
            drawLoadRibbon(ctx: &ctx, size: size)
            drawMemoryArc(ctx: &ctx, size: size)
            drawProcessTicks(ctx: &ctx, size: size)
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }

    /// 底部负载波形：铺满整幅宽度的面积图，压到几乎只剩一层影子。
    private func drawLoadRibbon(ctx: inout GraphicsContext, size: CGSize) {
        guard history.count >= 2 else { return }
        let baseY = size.height
        let bandH = size.height * 0.22
        let step = size.width / CGFloat(max(1, history.count - 1))

        var area = Path()
        area.move(to: CGPoint(x: 0, y: baseY))
        for (i, v) in history.enumerated() {
            let x = CGFloat(i) * step
            let y = baseY - bandH * CGFloat(min(1, max(0, v / 100)))
            area.addLine(to: CGPoint(x: x, y: y))
        }
        area.addLine(to: CGPoint(x: size.width, y: baseY))
        area.closeSubpath()

        ctx.fill(area, with: .linearGradient(
            Gradient(colors: [theme.primary.opacity(0.10), theme.primary.opacity(0.0)]),
            startPoint: CGPoint(x: 0, y: baseY - bandH),
            endPoint: CGPoint(x: 0, y: baseY)))

        var line = Path()
        for (i, v) in history.enumerated() {
            let x = CGFloat(i) * step
            let y = baseY - bandH * CGFloat(min(1, max(0, v / 100)))
            if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(line, with: .color(theme.primary.opacity(0.16)), lineWidth: 1.2)
    }

    /// 内存环：立绘身后一圈开口的弧，占用越高弧越长。压得比背景纸只深一点点。
    private func drawMemoryArc(ctx: inout GraphicsContext, size: CGSize) {
        guard let ratio = memoryRatio else { return }
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.38)
        let r = min(size.width, size.height) * 0.21

        var track = Path()
        track.addArc(center: center, radius: r, startAngle: .degrees(130),
                     endAngle: .degrees(410), clockwise: false)
        ctx.stroke(track, with: .color(Studio.hex(0x8A93A2, 0.045)), lineWidth: 1.2)

        var arc = Path()
        arc.addArc(center: center, radius: r, startAngle: .degrees(130),
                   endAngle: .degrees(130 + 280 * min(1, max(0, ratio))), clockwise: false)
        ctx.stroke(arc, with: .color(theme.primary.opacity(0.09)),
                   style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }

    /// 进程密度：沿外圈打一圈小点，进程越多点越密。纯氛围，不表示具体数值。
    private func drawProcessTicks(ctx: inout GraphicsContext, size: CGSize) {
        guard processCount > 0 else { return }
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.38)
        let r = min(size.width, size.height) * 0.26
        let ticks = min(72, max(12, processCount / 16))
        for i in 0..<ticks {
            let a = Double(i) / Double(ticks) * 2 * .pi - .pi / 2
            let p = CGPoint(x: center.x + CGFloat(cos(a)) * r,
                            y: center.y + CGFloat(sin(a)) * r)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)),
                     with: .color(Studio.hex(0x8A93A2, 0.09)))
        }
    }
}

/// 六界快速选择：一排圆头像，用于菜单栏 HUD 这种窄场合。
struct RealmPicker: View {
    @Binding var selection: AppView.Pane
    var size: CGFloat = 34
    var onPick: ((AppView.Pane) -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AppView.Pane.allCases) { pane in
                let theme = WuXingTheme.theme(for: pane)
                let active = pane == selection
                Button {
                    selection = pane
                    onPick?(pane)
                } label: {
                    VStack(spacing: 3) {
                        BeastAvatar(theme: theme, size: size)
                            .overlay(
                                Circle().strokeBorder(active ? theme.primary : .clear, lineWidth: 2)
                            )
                            .opacity(active ? 1 : 0.72)
                        Text(pane.title)
                            .font(.system(size: 9, weight: active ? .semibold : .regular))
                            .foregroundColor(active ? Studio.ink : Studio.inkTertiary)
                    }
                }
                .buttonStyle(.plain)
                .help("\(theme.beast) · \(pane.title)")
            }
        }
    }
}

extension View {
    @ViewBuilder
    func hideFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}
