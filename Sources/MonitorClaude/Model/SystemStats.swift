import Foundation
import Darwin

struct SystemStats {
    var cpuPercent: Double = 0        // 0...100, whole machine
    var memUsedBytes: UInt64 = 0
    var memTotalBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var loadAverage: Double = 0

    var memFraction: Double {
        memTotalBytes == 0 ? 0 : Double(memUsedBytes) / Double(memTotalBytes)
    }
}

/// Whole-machine CPU via host_processor_info tick deltas, memory via host_statistics64.
/// Ticks are cumulative, so the first sample only establishes a baseline.
final class SystemSampler {
    private var prevTicks: [UInt32]?
    private let pageSize: UInt64

    init() {
        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        pageSize = UInt64(ps)
    }

    func sample() -> SystemStats {
        var s = SystemStats()
        s.cpuPercent = sampleCPU()
        sampleMemory(into: &s)
        s.swapUsedBytes = sampleSwap()
        s.loadAverage = sampleLoad()
        return s
    }

    private func sampleCPU() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(UInt(infoCount) * UInt(MemoryLayout<integer_t>.size)))
        }

        let n = Int(cpuCount) * Int(CPU_STATE_MAX)
        var ticks = [UInt32](repeating: 0, count: n)
        for i in 0..<n { ticks[i] = UInt32(bitPattern: info[i]) }

        defer { prevTicks = ticks }
        guard let prev = prevTicks, prev.count == n else { return 0 }

        var busy: Double = 0
        var total: Double = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            for state in 0..<Int(CPU_STATE_MAX) {
                let d = Double(ticks[base + state] &- prev[base + state])
                total += d
                if state != Int(CPU_STATE_IDLE) { busy += d }
            }
        }
        guard total > 0 else { return 0 }
        return min(100, busy / total * 100)
    }

    private func sampleMemory(into s: inout SystemStats) {
        s.memTotalBytes = ProcessInfo.processInfo.physicalMemory

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        // Matches Activity Monitor's "Memory Used": anonymous + wired + compressed.
        let used = UInt64(vmStats.internal_page_count - vmStats.purgeable_count)
            + UInt64(vmStats.wire_count)
            + UInt64(vmStats.compressor_page_count)
        s.memUsedBytes = used * pageSize
    }

    private func sampleSwap() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        guard sysctl(&mib, 2, &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private func sampleLoad() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return 0 }
        return loads[0]
    }
}
