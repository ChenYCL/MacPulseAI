import XCTest
@testable import MacPulse

/// 应用卸载器与启动项扫描测试（临时 home 注入）。
final class UninstallerTests: XCTestCase {

    private var tempHome: URL!

    override func setUp() {
        super.setUp()
        tempHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MacPulseUninst-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        L10n.forced = .zh
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempHome)
        L10n.forced = nil
        super.tearDown()
    }

    private func makeApp(_ appsDir: URL, name: String, bundleID: String) -> URL {
        let appURL = appsDir.appendingPathComponent("\(name).app", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        <key>CFBundleName</key><string>\(name)</string>
        </dict></plist>
        """
        try? plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        try? "binary".write(to: appURL.appendingPathComponent("Contents/MacOS/bin"), atomically: true, encoding: .utf8)
        return appURL
    }

    private func touch(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? "data".write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: 应用扫描

    func testListAppsReadsBundleID() throws {
        let apps = tempHome.appendingPathComponent("Applications")
        makeApp(apps, name: "Demo", bundleID: "com.test.demo")
        makeApp(apps, name: "NoID", bundleID: "") // 无 bundleID 的应用跳过

        let list = AppUninstaller.listApps(appsDir: apps)
        XCTAssertEqual(list.count, 1, "空 bundleID 的应用应被跳过")
        XCTAssertEqual(list.first?.bundleID, "com.test.demo")
        XCTAssertEqual(list.first?.name, "Demo")
        XCTAssertGreaterThan(list.first?.sizeBytes ?? 0, 0)
    }

    // MARK: 残留扫描

    func testScanLeftoversFindsKnownLocations() {
        let lib = tempHome.appendingPathComponent("Library")
        touch(lib.appendingPathComponent("Preferences/com.test.demo.plist"))
        touch(lib.appendingPathComponent("Application Support/com.test.demo/data.db"))
        touch(lib.appendingPathComponent("Caches/com.test.demo"))
        touch(lib.appendingPathComponent("Containers/com.test.demo"))
        touch(lib.appendingPathComponent("Saved Application State/com.test.demo.savedState"))
        // 非相关文件不应出现
        touch(lib.appendingPathComponent("Preferences/com.other.plist"))

        let leftovers = AppUninstaller.scanLeftovers(bundleID: "com.test.demo",
                                                     appName: "Demo", home: tempHome)
        XCTAssertEqual(leftovers.count, 5)
        XCTAssertTrue(leftovers.contains { $0.url.lastPathComponent == "com.test.demo.plist" })
        XCTAssertTrue(leftovers.contains { $0.url.lastPathComponent == "com.test.demo" })
        XCTAssertFalse(leftovers.contains { $0.url.lastPathComponent == "com.other.plist" })
    }

    // MARK: 卸载安全裁决

    func testUninstallRunningAppRequiresQuitFirst() {
        let appURL = URL(fileURLWithPath: "/Applications/Demo.app")
        let running: Set<String> = [appURL.appendingPathComponent("Contents/MacOS/bin").path]
        let ruling = SafetyGuard.evaluateDeletion(
            urls: [appURL], home: tempHome, mode: .trash,
            runningExecutablePaths: running,
            explicitOutsideHomeAllowlist: [appURL])
        XCTAssertEqual(ruling.needsConfirm.count, 1, "运行中的应用应要求先退出")
        XCTAssertTrue(ruling.allowed.isEmpty)
    }

    func testUninstallAppExemptViaAllowlist() {
        let appURL = URL(fileURLWithPath: "/Applications/Demo.app")
        let ruling = SafetyGuard.evaluateDeletion(
            urls: [appURL], home: tempHome, mode: .trash,
            explicitOutsideHomeAllowlist: [appURL])
        XCTAssertEqual(ruling.allowed.count, 1, "/Applications 应用本体经显式豁免后允许移入废纸篓")
    }

    func testLeftoverWithoutExemptStillBlockedIfOutsideHome() {
        let ruling = SafetyGuard.evaluateDeletion(
            urls: [URL(fileURLWithPath: "/Library/AppSupport/evil")],
            home: tempHome, mode: .trash)
        XCTAssertEqual(ruling.blocked.count, 1, "残留清理同样不能触碰系统路径")
    }

    // MARK: 启动项扫描

    func testLaunchItemScanFindsUserAgents() throws {
        let agents = tempHome.appendingPathComponent("Library/LaunchAgents")
        try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>-m</string><string>x</string></array>
        </dict></plist>
        """
        try plist.write(to: agents.appendingPathComponent("com.test.helper.plist"), atomically: true, encoding: .utf8)

        let items = LaunchItemScanner.scan(home: tempHome)
        let user = items.first { $0.scope == .user }
        XCTAssertNotNil(user)
        XCTAssertEqual(user?.label, "com.test.helper")
        XCTAssertEqual(user?.program, "/usr/bin/python3")
    }

    func testSuspiciousHintForDownloadPath() {
        let item = LaunchItemScanner.LaunchItem(
            url: URL(fileURLWithPath: "/Users/tester/Downloads/evil.plist"),
            scope: .user, label: "evil", program: nil)
        XCTAssertNotNil(item.suspiciousHint)
    }

    // MARK: 维护任务注册

    func testRebuildLaunchServicesRegistered() {
        XCTAssertTrue(MaintenanceRunner.TaskKind.allCases.contains(.rebuildLaunchServices))
    }
}
