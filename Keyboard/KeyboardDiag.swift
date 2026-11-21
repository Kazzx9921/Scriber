import Foundation
import os
import ScriberShared

/// Keyboard diagnostics → the shared DiagLog (Settings › 診斷紀錄 in the app).
/// Rule: events, states, ids, lengths and error names only. Never transcripts, inserted text,
/// selected text or keys.
enum KBLog {
    static func log(_ message: String) {
        DiagLog.log("kb", message)
    }

    /// First 8 characters of a request id: enough to follow one request through both processes.
    static func id(_ id: String?) -> String {
        id.map { String($0.prefix(8)) } ?? "-"
    }

    /// Bytes the process may still allocate before iOS ends it (0 when the system does not say,
    /// e.g. in the Simulator).
    static var headroomBytes: UInt64 {
        UInt64(os_proc_available_memory())
    }

    /// Physical footprint, the number jetsam compares against the extension's limit.
    static var footprintBytes: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static var memory: String {
        String(format: "mem=%.1fMB headroom=%.1fMB",
               Double(footprintBytes) / 1_048_576, Double(headroomBytes) / 1_048_576)
    }

    static func millis(since date: Date) -> Int {
        Int((Date().timeIntervalSince(date) * 1000).rounded())
    }
}
