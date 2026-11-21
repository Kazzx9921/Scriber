import ServiceManagement
import ScriberShared

/// 「登入時自動開啟」 through `SMAppService.mainApp` (macOS 13+).
enum LaunchAtLogin {
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The user still has to allow it in System Settings → General → Login Items.
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns nil on success, else a short zh-Hant problem.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            DiagLog.log("app", "launchAtLogin set=\(enabled) status=\(statusDescription)")
            return nil
        } catch {
            DiagLog.log("app", "launchAtLogin set=\(enabled) failed \(MacDiag.error(error)) status=\(statusDescription)")
            return enabled ? "無法設定登入時開啟" : "無法取消登入時開啟"
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
