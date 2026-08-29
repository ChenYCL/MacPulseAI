import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = MonitorModel()
    let store = SettingsStore()
    /// 主窗口和菜单栏 HUD 共用同一个实例。曾经 HUD 用的是 DiskModel.sharedForHUD——
    /// 另一份只被 refreshFreeBytes() 碰过的对象，于是两处「土库/可用空间」会给出不同的数。
    @MainActor let disk = DiskModel()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var hudPopover: NSPopover?
    var statusMenu: NSMenu?
    private var pauseMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 影棚亮色主题：中性画布 + 去背立绘
        NSApp.appearance = NSAppearance(named: .aqua)
        setupMainMenu()
        L10n.overrideCode = store.settings.uiLanguage
        model.apply(settings: store.settings)
        model.onLoadUpdate = { [weak self] load in
            self?.updateStatusItem(load: load)
        }

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = L10n.s("MacPulse AI — 五气朝元", "MacPulse AI — Five Elements")
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        // 不要开 isMovableByWindowBackground：星轨那一片在 AppKit 眼里是「背景」，
        // 用户想横向拖着转轨，结果拖动的是整个窗口。标题栏区域照样能拖窗口。
        win.isMovableByWindowBackground = false
        win.isOpaque = true
        // 程序化创建的 NSWindow 默认 isReleasedWhenClosed = true：用户点关闭按钮后
        // AppKit 会把窗口对象整个释放，而 AppDelegate.window 还持有悬垂指针，
        // 之后从菜单栏 HUD 或 Dock reopen 调 makeKeyAndOrderFront 就是 SIGSEGV
        // （诊断报告里五起崩溃全中）。关掉它，close 只隐藏窗口，对象归 ARC 管。
        win.isReleasedWhenClosed = false
        win.backgroundColor = NSColor(calibratedRed: 0.949, green: 0.957, blue: 0.965, alpha: 1)
        win.minSize = NSSize(width: 1100, height: 740)
        win.contentView = NSHostingView(rootView: AppView(model: model, store: store, disk: disk))
        win.center()
        win.setFrameAutosaveName("MacPulseMain")
        win.makeKeyAndOrderFront(nil)
        win.delegate = self
        window = win

        setupStatusItem()
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        revealPaneFromLaunchArguments()
    }

    /// `--pane status|clean|software|optimize|analyze|security`
    /// 直接落到某个工作页。给 scripts/sweep.sh 逐页截图用——
    /// 用坐标点击顶栏在窗口一挪位置就全错，用启动参数才是可复现的。
    private func revealPaneFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--pane"), i + 1 < args.count else { return }
        let raw = args[i + 1]
        guard AppView.Pane(rawValue: raw) != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NotificationCenter.default.post(name: .macPulseRevealPane, object: raw)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        Task { @MainActor in
            guard let win = notification.object as? NSWindow else { return }
            self.model.setWindowVisible(win.occlusionState.contains(.visible))
        }
    }

    /// 程序化创建的 NSApplication 没有主菜单；macOS 的 ⌘C/⌘V/⌘X/⌘A/⌘Z 快捷键
    /// 挂在「编辑」菜单项上，缺失会导致设置面板无法粘贴 API Key。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: L10n.s("关于 MacPulse AI", "About MacPulse AI"),
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L10n.s("隐藏 MacPulse AI", "Hide MacPulse AI"),
                                   action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: L10n.s("退出 MacPulse AI", "Quit MacPulse AI"),
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L10n.s("编辑", "Edit"))
        editMenu.addItem(NSMenuItem(title: L10n.s("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: L10n.s("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: L10n.s("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: L10n.s("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: L10n.s("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: L10n.s("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: L10n.s("窗口", "Window"))
        windowMenu.addItem(NSMenuItem(title: L10n.s("最小化", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: L10n.s("关闭窗口", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let seal = MythAsset.template("menubar-seal", pointSize: 18) {
            item.button?.image = seal
            item.button?.imagePosition = .imageLeading
            item.button?.imageScaling = .scaleProportionallyDown
        }
        item.button?.title = " --%"

        // 左键弹五行 HUD；右键传统菜单。不要挂 item.menu，否则左键会被菜单抢走。
        let menu = NSMenu()
        let openItem = NSMenuItem(title: L10n.s("打开 MacPulse AI", "Open MacPulse AI"),
                                  action: #selector(showMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let pause = NSMenuItem(title: L10n.s("暂停刷新", "Pause Refreshing"),
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        pauseMenuItem = pause
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.s("退出 MacPulse AI", "Quit MacPulse AI"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusMenu = menu

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .aqua)
        let hud = MenuHUDView(model: model,
                              disk: disk,
                              onOpenMainWindow: { [weak self] in
                                  self?.hudPopover?.performClose(nil)
                                  self?.showMainWindow()
                              },
                              onOpenPane: { [weak self] pane in
                                  self?.hudPopover?.performClose(nil)
                                  NotificationCenter.default.post(name: .macPulseRevealPane, object: pane.rawValue)
                                  self?.showMainWindow()
                              },
                              onQuit: { NSApp.terminate(nil) })
        let hosting = NSHostingController(rootView: hud)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        hudPopover = popover

        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @MainActor
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            // 用 sender：NSStatusItem.button 是可选的，菜单栏溢出、用户 ⌘ 拖走状态项、
            // 快速用户切换重建菜单栏时都会是 nil，强解包会把整个 app（连同监控和在跑的 AI 流）带走。
            statusMenu?.popUp(positioning: nil,
                              at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
                              in: sender)
        } else {
            toggleHudPopover()
        }
    }

    @MainActor
    private func toggleHudPopover() {
        guard let button = statusItem?.button else { return }
        if let hud = hudPopover, hud.isShown {
            hud.performClose(nil)
            model.setHUDVisible(false)
        } else {
            model.setHUDVisible(true)
            hudPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            hudPopover?.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func showMainWindow() {
        guard let win = window else { return }
        // 关闭只是隐藏（isReleasedWhenClosed = false），最小化则进了 Dock；
        // 这两种状态点「打开主窗口」都要能真正回到屏幕前。
        if win.isMiniaturized { win.deminiaturize(nil) }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePause() {
        Task { @MainActor in
            model.isPaused.toggle()
            pauseMenuItem?.title = model.isPaused ? L10n.s("恢复刷新", "Resume Refreshing")
                                                  : L10n.s("暂停刷新", "Pause Refreshing")
        }
    }

    private func updateStatusItem(load: SystemLoad) {
        guard let button = statusItem?.button else { return }
        let text = NSMutableAttributedString(string: String(format: " %.0f%%", load.totalPercent))
        let full = NSRange(location: 0, length: text.length)
        if load.totalPercent >= 80 {
            text.addAttribute(.foregroundColor, value: NSColor.systemRed, range: full)
        } else if load.totalPercent >= 50 {
            text.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: full)
        }
        button.attributedTitle = text
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
