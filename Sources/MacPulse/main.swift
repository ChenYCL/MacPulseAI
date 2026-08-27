import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = MonitorModel()
    let store = SettingsStore()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        L10n.overrideCode = store.settings.uiLanguage
        model.apply(settings: store.settings)
        model.onLoadUpdate = { [weak self] load in
            self?.updateStatusItem(load: load)
        }

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 660),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = L10n.s("MacPulse AI — AI 进程管家", "MacPulse AI — AI Process Manager")
        win.contentView = NSHostingView(rootView: AppView(model: model, store: store))
        win.center()
        win.setFrameAutosaveName("MacPulseMain")
        win.makeKeyAndOrderFront(nil)
        win.delegate = self
        window = win

        setupStatusItem()
        model.start()
        NSApp.activate(ignoringOtherApps: true)
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
        item.button?.title = "CPU --%"

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
        item.menu = menu
        statusItem = item
    }

    @objc private func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
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
        let text = NSMutableAttributedString(string: String(format: "CPU %.0f%%", load.totalPercent))
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
