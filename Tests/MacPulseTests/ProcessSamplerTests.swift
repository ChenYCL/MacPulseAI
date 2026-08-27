import XCTest
@testable import MacPulse

final class ProcessSamplerTests: XCTestCase {

    // MARK: CPU TIME 解析

    private func seconds(_ s: String) throws -> Double {
        try XCTUnwrap(PSParser.parseCPUTimeSeconds(s))
    }

    func testParseCPUTimeSeconds() throws {
        XCTAssertEqual(try seconds("0:00.00"), 0, accuracy: 0.0001)
        XCTAssertEqual(try seconds("0:00.03"), 0.03, accuracy: 0.0001)
        XCTAssertEqual(try seconds("10:45.07"), 645.07, accuracy: 0.001)
        XCTAssertEqual(try seconds("25:31:08.36"), Double(25) * 3600 + Double(31) * 60 + 8.36, accuracy: 0.01)
        XCTAssertEqual(try seconds("2-03:04:05"), Double(2) * 86400 + Double(3) * 3600 + Double(4) * 60 + 5, accuracy: 0.001)
        XCTAssertNil(PSParser.parseCPUTimeSeconds("abc"))
        XCTAssertNil(PSParser.parseCPUTimeSeconds(""))
    }

    // MARK: ps 行解析

    /// 行格式：pid user uid state time pcpu pmem rss ucomm(可含空格)
    func testParseLineWithSpacesInUcomm() {
        let line = "80329 light 501 S 0:05.56 1.8 0.7 123456 Google Chrome"
        let p = PSParser.parseLine(line)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.pid, 80329)
        XCTAssertEqual(p?.user, "light")
        XCTAssertEqual(p?.uid, 501)
        XCTAssertEqual(p?.state, "S")
        XCTAssertEqual(p?.cpuTimeSeconds ?? 0, 5.56, accuracy: 0.001)
        XCTAssertEqual(p?.pcpu, 1.8)
        XCTAssertEqual(p?.pmem, 0.7)
        XCTAssertEqual(p?.rssKB, 123456)
        XCTAssertEqual(p?.ucomm, "Google Chrome")
    }

    func testParseLineKernelProcess() {
        let line = "0 root 0 R 5:03:49.52 14.0 0.0 0 kernel_task"
        let p = PSParser.parseLine(line)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.pid, 0)
        XCTAssertEqual(p?.uid, 0)
        let expectedSeconds: Double = Double(5 * 3600) + Double(3 * 60) + 49.52
        XCTAssertEqual(p?.cpuTimeSeconds ?? 0, expectedSeconds, accuracy: 0.01)
        XCTAssertEqual(p?.ucomm, "kernel_task")
    }

    func testParseOutputSkipsGarbageLines() {
        let out = """
        garbage line here

        200 root 0 Ss 0:01.00 0.0 0.0 1024 syslogd
        bad,data,line
        300
        """
        let lines = PSParser.parseOutput(out)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.pid, 200)
    }

    // MARK: 瞬时 CPU 计算（含路径与线程注入）

    private func makeSampler(_ outputs: [String], times: [Date], cores: Int = 4) -> ProcessSampler {
        var out = outputs
        var t = times
        return ProcessSampler(
            readOutput: { out.removeFirst() },
            now: { t.removeFirst() },
            cores: cores,
            pidsProvider: { [100, 200, 300] },
            pathProvider: { pid in
                switch pid {
                case 100: return "/usr/bin/yes"
                case 300: return "/Applications/My Tools.app/Contents/MacOS/node"
                default: return nil
                }
            },
            threadsProvider: { pid in pid == 100 ? 1 : (pid == 300 ? 28 : nil) }
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testInstantaneousCPUFromTwoSamplesAndClamp() throws {
        let out1 = """
        100 light 501 R 0:02.00 0.0 0.0 4096 yes
        200 root 0 Ss 0:01.00 0.0 0.0 1024 syslogd
        """
        // yes 累计 CPU 时间 2s → 10s，墙钟 2s → 400%（4 核满载，正好等于 clamp 上限）
        let out2 = """
        100 light 501 R 0:10.00 0.0 0.0 4096 yes
        200 root 0 Ss 0:01.00 0.0 0.0 1024 syslogd
        """
        let sampler = makeSampler([out1, out2], times: [t0, t0.addingTimeInterval(2)])

        let first = try sampler.sample()
        let firstYes = try XCTUnwrap(first.first { $0.pid == 100 })
        XCTAssertEqual(firstYes.cpuPercent, 0.0, accuracy: 0.001, "首采无差值，应回落到 ps 的 pcpu=0.0")
        XCTAssertEqual(firstYes.name, "yes", "路径来自 proc_pidpath")
        XCTAssertEqual(firstYes.path, "/usr/bin/yes")
        XCTAssertEqual(firstYes.threads, 1)
        XCTAssertTrue(firstYes.isOwnedByMe)

        let syslogd = try XCTUnwrap(first.first { $0.pid == 200 })
        XCTAssertFalse(syslogd.isOwnedByMe, "root 进程不属于当前用户")
        XCTAssertEqual(syslogd.threads, 0, "其他用户进程线程数不可读")

        let second = try sampler.sample()
        let yes = try XCTUnwrap(second.first { $0.pid == 100 })
        XCTAssertEqual(yes.cpuPercent, 400, accuracy: 0.5, "8s CPU / 2s 墙钟 = 400%，等于 4 核上限")
        let sys = try XCTUnwrap(second.first { $0.pid == 200 })
        XCTAssertEqual(sys.cpuPercent, 0, accuracy: 0.001, "CPU 时间无增长 → 0%")
    }

    func testNewProcessFallsBackToPCPU() throws {
        let out1 = "100 light 501 R 0:02.00 0.0 0.0 4096 yes"
        let out2 = """
        100 light 501 R 0:02.50 0.0 0.0 4096 yes
        300 light 501 R 0:00.10 50.0 1.5 65536 node
        """
        let sampler = makeSampler([out1, out2], times: [t0, t0.addingTimeInterval(1)])
        _ = try sampler.sample()
        let second = try sampler.sample()
        let node = try XCTUnwrap(second.first { $0.pid == 300 })
        XCTAssertEqual(node.cpuPercent, 50.0, accuracy: 0.001, "新进程首采应回落到 ps 的 pcpu")
        XCTAssertEqual(node.name, "node", "路径含空格时取最后一段")
        XCTAssertEqual(node.path, "/Applications/My Tools.app/Contents/MacOS/node")
        XCTAssertEqual(node.threads, 28)
    }

    func testFallsBackToUcommWhenNoPath() throws {
        let out1 = "0 root 0 R 5:03:49.52 14.0 0.0 0 kernel_task"
        let sampler = makeSampler([out1], times: [t0])
        let first = try sampler.sample()
        let kt = try XCTUnwrap(first.first { $0.pid == 0 })
        XCTAssertEqual(kt.name, "kernel_task", "proc_pidpath 失败时回落 ucomm")
        XCTAssertEqual(kt.path, "")
    }

    func testPIDReuseResetsAndDoesNotExplode() throws {
        // PID 复用导致累计时间倒退：delta 钳为 0，不应出现负值或崩溃
        let out1 = "100 light 501 R 1:00.00 0.0 0.0 4096 heavy"
        let out2 = "100 light 501 R 0:00.10 0.0 0.0 4096 light"
        let sampler = makeSampler([out1, out2], times: [t0, t0.addingTimeInterval(2)])
        _ = try sampler.sample()
        let second = try sampler.sample()
        let p = try XCTUnwrap(second.first { $0.pid == 100 })
        XCTAssertGreaterThanOrEqual(p.cpuPercent, 0)
    }
}
