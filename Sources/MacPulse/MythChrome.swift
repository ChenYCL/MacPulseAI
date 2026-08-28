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

/// 影棚背景：无缝背景纸。上白下灰的竖向渐变 + 主体区一团柔光 + 极淡暗角。
/// 不画地平线——参考里地面和背景是连着的一张纸，硬线只会把画面切断。
struct StudioBackdrop: View {
    let theme: WuXingTheme.Theme
    /// 柔光中心（单位坐标），角色站哪儿光就打哪儿。
    var lightCenter: UnitPoint = UnitPoint(x: 0.66, y: 0.44)
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
