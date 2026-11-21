import AppKit
import SwiftUI
import ScriberShared

/// 診斷紀錄 (sheet from 設定 → 進階): the event log (no speech, no text, no keys), newest at the
/// bottom, refreshed every second. "複製" adds a short header (versions, settings, permission
/// states) so it can be pasted back to the developer as is.
struct DiagnosticsView: View {
    var onDone: () -> Void

    @Environment(MacSettings.self) private var settings

    @State private var lines: [String] = []
    @State private var loadedLength = -1
    @State private var confirmClear = false
    @State private var copied = false

    /// Rendering more than this gets slow; the copy always takes the whole file.
    private static let maxLines = 1500

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("診斷紀錄").font(.headline)
                InfoButton("只記錄事件和狀態，不記錄說話內容、文字或 API key。出問題時按「複製」，整段貼給開發者。")
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if lines.isEmpty {
                            Text("還沒有紀錄").font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(lines.indices, id: \.self) { index in
                                Text(lines[index])
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .textSelection(.enabled)
                    .padding(12)
                }
                .onChange(of: lines.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            HStack {
                Button("清除…") { confirmClear = true }
                Spacer()
                Button(copied ? "已複製" : "複製") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(header + "\n" + DiagLog.read(), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Button("完成", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 520)
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .confirmationDialog("清除診斷紀錄？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                DiagLog.clear()
                reload()
            }
        }
    }

    private func reload() {
        let text = DiagLog.read()
        guard text.utf8.count != loadedLength else { return }
        loadedLength = text.utf8.count
        lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(Self.maxLines).map(String.init))
    }

    /// Read only when copying (the live controller; never touched while just showing the log).
    private var header: String {
        let controller = DictationController.shared
        let hotkey = HotkeyRuntime.shared.state
        return [
            "Scriber for Mac \(MacDiag.appVersion) · macOS \(MacDiag.osVersion) · \(MacDiag.machine)",
            "hotkey: \(settings.hotkey.logDescription) · tap=\(controller.hotkeyStatus.rawValue) failures=\(controller.hotkeyFailures) "
                + "active=\(Self.describe(hotkey.active)) combo=\(Self.describe(hotkey.combo))",
            "permissions: ax=\(controller.accessibilityTrusted) mic=\(controller.micPermission.rawValue) "
                + "secureInput=\(controller.secureInputActive) pasteboard=\(Permissions.pasteboardAccess) "
                + "launchAtLogin=\(LaunchAtLogin.statusDescription)",
            "settings: \(settings.logDescription)",
            "----",
        ].joined(separator: "\n")
    }

    private static func describe(_ active: ActiveHotkey) -> String {
        switch active {
        case .single(let key): "single(\(key.rawValue))"
        case .combo(let combo): "combo(\(combo.logDescription))"
        case .unavailable(let reason): "unavailable(\(reason))"
        }
    }

    private static func describe(_ registration: ComboRegistration) -> String {
        switch registration {
        case .off: "off"
        case .registered: "registered"
        case .taken(let conflict): "taken(\(conflict.rawValue))"
        }
    }
}
