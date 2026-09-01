import Foundation
import MachO

/// Memory / thermal sampling and per-backend run metrics.
///
/// `physFootprint` matches the "Memory" column in Xcode's debug gauge —
/// the number that must stay under the ~900 MB budget — so every peak
/// number reported by the benchmark is directly comparable with Instruments.
enum PerformanceMetrics {
    /// Resident memory footprint in bytes (task_vm_info.phys_footprint).
    static func physFootprint() -> Int64 {
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(taskInfo.phys_footprint)
    }

    /// Best-effort available RAM (advisory only, never a hard gate).
    static func availableMemory() -> Int64 {
        Int64(os_proc_available_memory())
    }

    static func thermalStateDescription() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    static func osVersionString() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    static func megabytes(_ bytes: Int64) -> Double {
        Double(bytes) / 1_000_000
    }
}

/// Timing and memory observations collected during one backend's benchmark
/// pass (load → N inferences → unload).
struct BackendRunMetrics: Sendable, Codable, Equatable {
    /// Wall-clock `prepare()` + `warmup()` duration.
    var loadDuration: TimeInterval = 0
    /// First real (non-warmup) inference latency.
    var firstInference: TimeInterval = 0
    /// Subsequent inference latencies.
    var warmInferences: [TimeInterval] = []
    var audioDurations: [TimeInterval] = []
    var inferenceDurations: [TimeInterval] = []
    /// Peak phys_footprint observed while this backend was resident.
    var peakMemoryBytes: Int64 = 0
    /// Footprint sampled right after unload (memory-release check).
    var postUnloadMemoryBytes: Int64 = 0
    var thermalState: String = ""

    /// Total inference time / total audio time. Empty audio → nil.
    var realTimeFactor: Double? {
        let audio = audioDurations.reduce(0, +)
        let compute = inferenceDurations.reduce(0, +)
        guard audio > 0 else { return nil }
        return compute / audio
    }

    /// Median of the warm (non-first) inferences.
    var medianWarmInference: TimeInterval? {
        let sorted = warmInferences.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }
}
