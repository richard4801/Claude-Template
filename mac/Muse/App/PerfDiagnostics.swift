import Darwin
import Foundation
import MuseCore
import os
import SwiftUI

/// Performance pass (plans/perf-audit.md "Mac"): numbers the owner can read on a real Mac.
/// - Console / `log stream`: `first content shown 812 ms after process start` (subsystem studio.muse.mac, category perf).
/// - Instruments: the "launch" and "first content shown" points of interest (Points of Interest track, App Launch template).
/// - Settings → Developer → Performance: the same startup number, memory, image cache, live streams and requests.
enum StartupMetrics {
    static let log = Logger(subsystem: "studio.muse.mac", category: "perf")
    static let signposter = OSSignposter(subsystem: "studio.muse.mac", category: .pointsOfInterest)

    /// Milliseconds from process start to the first lists in the store (nil until then, or when signed out).
    @MainActor private(set) static var firstContentMs: Double?

    /// When the kernel started this process, so the number includes dyld and static initialisers.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }()

    @MainActor static func launched() {
        _ = processStart
        signposter.emitEvent("launch")
    }

    /// The first time the store holds the lists after launch (models, takes): what Home draws.
    @MainActor static func firstContentShown(models: Int, takes: Int) {
        guard firstContentMs == nil else { return }
        let ms = Date().timeIntervalSince(processStart) * 1000
        firstContentMs = ms
        signposter.emitEvent("first content shown")
        log.notice("first content shown \(Int(ms), privacy: .public) ms after process start (\(models, privacy: .public) models, \(takes, privacy: .public) takes)")
    }
}

/// This process's memory, from `task_info` (what Activity Monitor's "Memory" column shows is the footprint).
enum MemoryReport {
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func resident() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.resident_size : nil
    }

    static func mb(_ bytes: UInt64?) -> String {
        guard let bytes else { return "–" }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

/// Settings → Developer → Performance: live numbers, refreshed every 2 s while the section is open.
struct PerfReadout: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 0) {
                SettingRow("Start-up", hint: "From launch to the first lists in the app (also in Console: subsystem studio.muse.mac, category perf).") {
                    RowValue(StartupMetrics.firstContentMs.map { "\(Int($0)) ms" } ?? "–")
                }
                SettingRow("Memory", hint: "Footprint (Activity Monitor's Memory), then resident.") {
                    RowValue("\(MemoryReport.mb(MemoryReport.footprint())) · \(MemoryReport.mb(MemoryReport.resident()))")
                }
                SettingRow("Images in memory", hint: "Decoded at display size; the cache gives way at \(ImageCache.memoryLimit >> 20) MB or when the Mac needs memory.") {
                    let s = ImageCacheStats.shared.snapshot
                    RowValue("\(s.count) · \(MemoryReport.mb(UInt64(s.bytes))) · \(ImageDataLoader.shared.downloads) downloads")
                }
                SettingRow("Live updates", hint: "Connections to the server's live stream (one is shared by every part of the app), then listeners.") {
                    RowValue("\(LiveEventHub.shared.openConnections) · \(LiveEventHub.shared.subscriberCount)")
                }
                SettingRow("Requests", hint: "Sent, answered by one already in flight, answered from the catalog cache.") {
                    let r = (store.api as? HTTPMuseAPI)?.requestStats
                    RowValue(r.map { "\($0.sent) · \($0.joined) · \($0.cacheHits)" } ?? "Demo")
                }
            }
        }
    }
}
