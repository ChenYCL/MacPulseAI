import Foundation
import Combine

/// 监控状态机：定时采样 → 发布进程列表与系统负载；提供终止进程入口。
@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var processes: [ProcSample] = []
    @Published private(set) var load: SystemLoad = .zero
    @Published private(set) var statusMessage: String?
    @Published var isPaused = false
    @Published var refreshInterval: Double = 2 {
        didSet {
            if oldValue != refreshInterval, isRunning { restartTimer() }
        }
    }

    let coreCount = ProcessInfo.processInfo.activeProcessorCount
    var onLoadUpdate: ((SystemLoad) -> Void)?

    private let sampler: ProcessSampler
    private let loadTracker = SystemLoadTracker()
    private var timer: Timer?
    private var isRunning = false
    private var latestProcesses: [ProcSample] = []
    /// 窗口不可见时跳过 SwiftUI 表格刷新（渲染占大头），打开窗口立即补一次。
    /// 由 AppDelegate 依据 NSWindow.occlusionState 维护。
    private var isWindowVisible = true

    nonisolated init(sampler: ProcessSampler = ProcessSampler()) {
        self.sampler = sampler
    }

    /// 供 UI 写入操作反馈信息。
    func setStatus(_ message: String?) {
        statusMessage = message
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        tick()
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = max(0.5, refreshInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func apply(settings: Settings) {
        refreshInterval = settings.refreshInterval
    }

    func tick() {
        guard !isPaused else { return }
        let l = loadTracker.current()
        load = l
        onLoadUpdate?(l)
        do {
            latestProcesses = try sampler.sample()
            if isWindowVisible { processes = latestProcesses }
        } catch {
            statusMessage = L10n.s("进程采样失败：\(error.localizedDescription)",
                                   "Process sampling failed: \(error.localizedDescription)")
        }
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        if visible { processes = latestProcesses }
    }

    /// 批量终止；结果写入 statusMessage。普通退出（SIGTERM）3 秒后复查，仍存活则提示可强制退出。
    func terminate(pids: [pid_t], force: Bool) {
        guard !pids.isEmpty else { return }
        var ok = 0
        var errors: [String] = []
        for pid in pids {
            if let err = ProcessKiller.terminate(pid: pid, force: force) {
                errors.append("PID \(pid)：\(err)")
            } else {
                ok += 1
                if !force { scheduleRecheck(pid) }
            }
        }
        let verb = force ? L10n.s("强制退出", "force quit") : L10n.s("退出", "quit")
        var msg: String
        if ok > 0 {
            msg = L10n.s("已对 \(ok) 个进程发送\(verb)信号",
                         "Sent \(verb) signal to \(ok) process(es)")
        } else {
            msg = L10n.s("未发送任何信号", "No signal was sent")
        }
        if !errors.isEmpty { msg += "；" + errors.joined(separator: "；") }
        statusMessage = msg
        tick()
    }

    private func scheduleRecheck(_ pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, ProcessKiller.isAlive(pid) else { return }
                self.statusMessage = L10n.s("PID \(pid) 仍在运行，可尝试「强制退出」",
                                            "PID \(pid) is still running; try Force Quit")
            }
        }
    }
}
