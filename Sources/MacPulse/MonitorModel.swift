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
    /// 采样专用串行队列：sampler 的内部缓存只在这条队列上被访问。
    private let samplingQueue = DispatchQueue(label: "com.chenycl.macpulseai.sampling", qos: .utility)
    private var isSampling = false
    private var timer: Timer?
    private var isRunning = false
    private(set) var latestProcesses: [ProcSample] = []
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
        // 这几项是 mach/sysctl 直接读取，微秒级，留在主线程无妨
        let l = loadTracker.current()
        load = l
        onLoadUpdate?(l)
        refreshMemoryStats()

        // 进程采样要 fork /bin/ps 并 waitUntilExit，实测 100ms+（系统负载高时更久）。
        // 放在主线程会周期性阻塞事件循环：⌘Q 恰好落进这段阻塞就会被系统判为
        // 「应用无响应」，用户只能强制退出。这里挪到串行后台队列，主线程只做发布。
        guard !isSampling else { return }   // 上一轮未返回则跳过本轮，避免任务堆积
        isSampling = true
        let sampler = self.sampler
        samplingQueue.async { [weak self] in
            let result = Result { try sampler.sample() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSampling = false
                self.applySample(result)
            }
        }
    }

    private func applySample(_ result: Result<[ProcSample], Error>) {
        switch result {
        case .success(let procs):
            latestProcesses = procs
            if isWindowVisible { processes = procs }
        case .failure(let error):
            statusMessage = L10n.s("进程采样失败：\(error.localizedDescription)",
                                   "Process sampling failed: \(error.localizedDescription)")
        }
    }

    /// 内存压力：物理内存占用比 + Swap 使用量（sysctl vm.swapusage）。
    private func refreshMemoryStats() {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &size)
            }
        }
        if kr == KERN_SUCCESS {
            let usedBytes = Double(UInt64(stats.active_count) + UInt64(stats.wire_count)
                                   + UInt64(stats.compressor_page_count)) * Double(vm_page_size)
            memoryUsedPercent = (usedBytes / Double(ProcessInfo.processInfo.physicalMemory) * 100 * 10).rounded() / 10
        }

        var buffer = [CChar](repeating: 0, count: 256)
        var sz = buffer.count
        guard sysctlbyname("vm.swapusage", &buffer, &sz, nil, 0) == 0 else { return }
        let raw = String(cString: buffer) // e.g. "total = 1024.00M used = 512.00M free = 512.00M"
        guard let range = raw.range(of: #"used\s*=\s*([\d.]+\s*[MG])"#, options: .regularExpression) else {
            swapUsedText = nil
            return
        }
        swapUsedText = String(raw[range])
            .components(separatedBy: "=").last?
            .trimmingCharacters(in: .whitespaces)
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        if visible { processes = latestProcesses }
    }

    /// 批量终止；结果写入 statusMessage。普通退出（SIGTERM）3 秒后复查，仍存活则提示可强制退出。
    @Published private(set) var swapUsedText: String?
    @Published private(set) var memoryUsedPercent: Double?

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
