import Darwin

/// 通过 mach host_processor_info 的 CPU tick 差值计算系统级 user/sys/idle 百分比。
final class SystemLoadTracker {
    private var prev: (user: UInt64, nice: UInt64, system: UInt64, idle: UInt64)?
    private(set) var last = SystemLoad.zero

    func current() -> SystemLoad {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count)
        guard kr == KERN_SUCCESS, let arr = info, numCPUs > 0 else { return last }
        defer {
            let size = vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)
            _ = vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: arr)), size)
        }

        var user = UInt64(0), nice = UInt64(0), system = UInt64(0), idle = UInt64(0)
        for i in 0..<Int(numCPUs) {
            let base = i * Int(CPU_STATE_MAX)
            user += UInt64(arr[base + Int(CPU_STATE_USER)])
            nice += UInt64(arr[base + Int(CPU_STATE_NICE)])
            system += UInt64(arr[base + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(arr[base + Int(CPU_STATE_IDLE)])
        }

        if let p = prev {
            let du = user > p.user ? user - p.user : 0
            let dn = nice > p.nice ? nice - p.nice : 0
            let ds = system > p.system ? system - p.system : 0
            let di = idle > p.idle ? idle - p.idle : 0
            let total = du + dn + ds + di
            if total > 0 {
                last = SystemLoad(userPercent: Double(du + dn) / Double(total) * 100,
                                  systemPercent: Double(ds) / Double(total) * 100,
                                  idlePercent: Double(di) / Double(total) * 100)
            }
        }
        prev = (user, nice, system, idle)
        return last
    }
}
