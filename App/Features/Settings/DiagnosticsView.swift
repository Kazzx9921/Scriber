import SwiftUI
import UIKit
import ScriberShared

/// 設定 → 診斷紀錄: the shared diagnostic log written by the app and the keyboard, newest at the
/// bottom, refreshed every second. "複製" adds a short header (versions and settings, nothing
/// personal) so the text can be pasted back to the developer as is.
struct DiagnosticsView: View {
    @Environment(DictationEngine.self) private var engine
    @Environment(SettingsModel.self) private var settings

    @State private var lines: [String] = []
    @State private var loadedBytes = -1
    @State private var confirmClear = false
    @State private var copied = false
    @State private var keepAliveCategory = StandbyMemory.keepAliveCategory

    /// Rendering more than this gets slow; the copy always takes the whole file.
    private static let maxLines = 1500

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusCard
                    if lines.isEmpty {
                        Text("還沒有紀錄。用鍵盤說一次話之後再回來看。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(lines.indices, id: \.self) { index in
                                Text(lines[index])
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: lines.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .task {
                while !Task.isCancelled {
                    reload()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        .navigationTitle("診斷紀錄")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("輸出待命閒置時", selection: $keepAliveCategory) {
                        Text("播放模式（預設）").tag(AudioRecorder.KeepAliveCategory.playback)
                        Text("錄音模式（不切換）").tag(AudioRecorder.KeepAliveCategory.playAndRecord)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("開發者選項")
                }
            }
        }
        .onChange(of: keepAliveCategory) { _, value in
            StandbyMemory.keepAliveCategory = value
            DiagLog.log("app", "dev keepAliveCategory=\(value.rawValue) (applies from the next standby)")
        }
        .bottomBar {
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = header + "\n" + DiagLog.read()
                    copied = true
                    Haptics.success()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    FullWidthLabel(copied ? "已複製" : "複製")
                }
                .primaryActionStyle()

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    FullWidthLabel("清除")
                }
                .secondaryActionStyle()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .confirmationDialog("要清除診斷紀錄嗎？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                DiagLog.clear()
                DiagLog.log("app", "log cleared by the user")
                loadedBytes = -1
                reload()
            }
        }
    }

    // MARK: Pieces

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("背景待命", engine.isSessionActive ? "有" : "沒有")
            row("麥克風", postureText)
            if let expires = engine.sessionExpiresAt, engine.isSessionActive {
                row("待命到", expires.formatted(date: .omitted, time: .standard))
            }
            row("待命方式", modeText)
        }
        .font(.footnote)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private var postureText: String {
        switch engine.posture {
        case .released: return "關閉"
        case .live: return "開著"
        case .muted: return "開著但靜音"
        case .keepAlive: return "關閉（無聲播放保持待命）"
        }
    }

    private var modeText: String {
        let chosen = settings.standbyMode
        let effective = engine.effectiveStandbyMode
        if chosen != effective { return "\(chosen.displayName)（目前改用\(effective.displayName)）" }
        return chosen == .off ? chosen.displayName : "\(chosen.displayName)・\(settings.standbyMinutes) 分鐘"
    }

    /// Versions and settings only: nothing the user said, typed or stored as a key.
    private var header: String {
        let now = Date().formatted(.iso8601)
        return "Scriber 診斷紀錄 \(now)\n"
            + "app=\(EngineDiag.appVersion) iOS=\(UIDevice.current.systemVersion) device=\(EngineDiag.deviceModel)\n"
            + "standby=\(settings.standbyMode.rawValue)/\(settings.standbyMinutes)m effective=\(engine.effectiveStandbyMode.rawValue) "
            + "keepAliveCat=\(StandbyMemory.keepAliveCategory.rawValue) refused=\(engine.outputOnlyRefusal?.error ?? "no")\n"
            + "autoReturn=\(settings.autoReturn) target=\(settings.autoReturnTargetID ?? "none") kbCapture=\(settings.inKeyboardCapture) "
            + "session=\(engine.isSessionActive) posture=\(engine.posture.rawValue)\n"
            + "----"
    }

    private func reload() {
        let text = DiagLog.read()
        let bytes = text.utf8.count
        guard bytes != loadedBytes else { return }
        loadedBytes = bytes
        var all = text.split(separator: "\n", omittingEmptySubsequences: true)
        if all.count > Self.maxLines { all = Array(all.suffix(Self.maxLines)) }
        lines = all.map(String.init)
    }
}
