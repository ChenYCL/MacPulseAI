import Darwin
import Foundation

/// 进程终止：仅允许终止当前用户拥有的进程；root 进程给出明确错误（v1 不做提权）。
enum ProcessKiller {
    /// 通过 sysctl KERN_PROC_PID 查询进程属主 uid；进程不存在返回 nil。
    static func uid(of pid: pid_t) -> uid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// 发送信号；成功返回 nil，失败返回错误描述。
    static func terminate(pid: pid_t, force: Bool) -> String? {
        guard let owner = uid(of: pid) else {
            return L10n.s("进程不存在或已退出", "Process does not exist or has exited")
        }
        if owner != getuid() {
            return L10n.s("进程属于其他用户（uid \(owner)），需要 root 权限，当前版本不支持提权终止",
                          "Process is owned by another user (uid \(owner)); root privileges required, elevation not supported yet")
        }
        let sig: Int32 = force ? SIGKILL : SIGTERM
        if kill(pid, sig) != 0 {
            switch errno {
            case EPERM: return L10n.s("权限不足（EPERM）", "Permission denied (EPERM)")
            case ESRCH: return L10n.s("进程不存在或已退出", "Process does not exist or has exited")
            default: return String(cString: strerror(errno))
            }
        }
        return nil
    }
}
