import SwiftUI
import ScriberShared

/// 設定 → 實驗功能: standby, auto-return, in-keyboard capture and the diagnostic log.
/// Kept off the main settings list so it stays short.
struct ExperimentalSettingsView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(DictationEngine.self) private var engine

    var body: some View {
        @Bindable var settings = settings

        Form {
            // MARK: Standby
            Section {
                ForEach(StandbyMode.allCases) { mode in
                    ProviderRow(title: mode.displayName, tag: mode.tag, isSelected: settings.standbyMode == mode) {
                        if settings.standbyMode != mode {
                            settings.standbyMode = mode
                            Haptics.tap()
                        }
                    }
                }
            } header: {
                SectionTitle("待命方式") {
                    InfoText("待命時 Scriber 會留在背景等鍵盤叫它，會多用一點電。這些方式還在實機測試。")
                    ForEach(StandbyMode.allCases) { mode in
                        InfoItem(title: mode.displayName, text: mode.tradeoff)
                    }
                }
            }

            if settings.standbyMode != .off {
                Section {
                    if settings.standbyMode == .outputOnly, let refusal = engine.outputOnlyRefusal {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(refusal.at.formatted(date: .abbreviated, time: .shortened)) iOS 不讓 Scriber 在背景打開麥克風，暫時改成「講完即關」。",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            Button("再試一次輸出待命") { engine.retryOutputOnly() }
                                .font(.subheadline)
                        }
                        .padding(.vertical, 2)
                    }
                    Picker("待命時間", selection: $settings.standbyMinutes) {
                        ForEach(standbyMinuteOptions, id: \.self) { minutes in
                            Text("\(minutes) 分鐘").tag(minutes)
                        }
                    }
                } footer: {
                    Text("最後一次說話後，超過這段時間就結束待命。")
                }
            }

            // MARK: Auto-return
            Section {
                Toggle("自動跳回原本的 App", isOn: $settings.autoReturn)
                if settings.autoReturn {
                    Picker("跳回", selection: $settings.autoReturnTargetID) {
                        Text("不自動跳回").tag(String?.none)
                        ForEach(AutoReturnCatalog.all) { target in
                            Text(target.verified ? target.name : "\(target.name)（未實測）").tag(target.id as String?)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            } header: {
                SectionTitle("跳回", info: "iOS 不讓鍵盤知道你正在哪個 App 打字，所以 Scriber 只能跳回你在這裡選的 App。常在不同 App 用的話，選「不自動跳回」，點左上角的「◀︎」回去就好。")
            }

            // MARK: In-keyboard capture
            Section {
                Toggle("在鍵盤內直接錄音", isOn: $settings.inKeyboardCapture)
                    .disabled(!Self.supportsInKeyboardCapture)
            } header: {
                SectionTitle("鍵盤錄音", info: Self.supportsInKeyboardCapture
                             ? "讓鍵盤自己錄音，完全不用跳到 Scriber。需要 iOS 26 以上。"
                             : "需要 iOS 26 以上，這支手機的系統版本不支援。")
            }

            // MARK: Diagnostics
            Section {
                NavigationLink("診斷紀錄") { DiagnosticsView() }
            } footer: {
                Text("紀錄裡沒有你說的內容或 API key。")
            }
        }
        .navigationTitle("實驗功能")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static var supportsInKeyboardCapture: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Known durations plus whatever is stored.
    private var standbyMinuteOptions: [Int] {
        var options = SettingsModel.standbyMinuteOptions
        if !options.contains(settings.standbyMinutes) { options.append(settings.standbyMinutes); options.sort() }
        return options
    }
}
