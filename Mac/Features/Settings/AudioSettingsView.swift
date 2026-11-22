import SwiftUI
import UniformTypeIdentifiers

/// 設定 → 音訊, in the page's row style (title left, one control right, explanations behind "?",
/// captions only for live problems):
/// 1. 麥克風 — 跟隨系統 or one device (live list); 測試 runs the meter for a few seconds on request.
/// 2. 錄音時靜音其他聲音.
/// 3. 錄音時暫停媒體 (unavailable with its reason behind "?" where macOS does not allow it), and
///    under it, only when on, 恢復播放 (delay).
/// 4. 提示音 behind a disclosure (rarely changed): 開始 / 結束 (預設 / 無 / 自訂 / 選擇檔案…, ▶ 試聽)
///    and 音量.
struct AudioSettingsSection: View {
    let model: AudioSettingsModel

    @State private var cuesExpanded: Bool
    @State private var showImporter = false
    @State private var importTarget: CueKind = .start
    @State private var volume: Double

    /// `showsCues`: snapshot renders start with 提示音 open.
    init(model: AudioSettingsModel, showsCues: Bool = false) {
        self.model = model
        _cuesExpanded = State(initialValue: showsCues)
        _volume = State(initialValue: model.prefs.cueVolume)
    }

    var body: some View {
        @Bindable var model = model
        Section {
            MicrophoneRow(model: model)

            Toggle(isOn: $model.prefs.muteOutput) {
                HStack(spacing: 4) {
                    Text("錄音時靜音其他聲音")
                    InfoButton("錄音時把 Mac 正在播放的聲音關掉，結束後恢復原本的音量。開始的提示音會先播完。")
                }
            }

            pauseMediaRow

            if model.prefs.pauseMedia, !isMediaUnavailable {
                Picker("恢復播放", selection: $model.prefs.resumeDelay) {
                    ForEach(AudioPreferences.resumeDelayChoices, id: \.self) { delay in
                        Text(Self.delayName(delay)).tag(delay)
                    }
                }
                .pickerStyle(.menu)
                .padding(.leading, 26)
            }

            DisclosureGroup(isExpanded: $cuesExpanded) {
                // Rows of their own inside the disclosure, separated like the form's rows.
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    cueRow(.start).padding(.vertical, 8)
                    Divider()
                    cueRow(.stop).padding(.vertical, 8)
                    if model.anyCuePlays {
                        Divider()
                        volumeRow
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack {
                    Text("提示音")
                    Spacer(minLength: 8)
                    Text(model.cueSummary).foregroundStyle(.secondary)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.importCue(importTarget, from: url)
                }
            }
        } header: {
            SectionHeader("音訊") { Self.explanations }
        }
    }

    /// Behind the section's "?".
    @ViewBuilder
    static var explanations: some View {
        InfoItem(title: "麥克風", text: "「跟隨系統」用 macOS 聲音設定裡選的輸入裝置。指定的麥克風沒接上時，那次錄音改用系統的，接回來後自動再用它。")
        InfoItem(title: "藍牙耳機", text: "用 AirPods 等藍牙耳機的麥克風錄音時，耳機會切到通話模式，錄音期間聽到的聲音和錄到的音質都會變差。")
        InfoItem(title: "測試", text: "開麥克風 5 秒，看聲音有沒有進來。")
        InfoItem(title: "提示音", text: "可以換成自己的聲音檔（5 秒以內）。音量是相對於 Mac 的音量。")
    }

    /// 音量 (only while some cue plays): stored when the slider is released, then played once.
    private var volumeRow: some View {
        HStack(spacing: 8) {
            Text("音量")
            Spacer(minLength: 12)
            Slider(value: $volume, in: AudioPreferences.cueVolumeRange) {
                Text("音量")
            } minimumValueLabel: {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            } onEditingChanged: { editing in
                if !editing { model.commitVolume(volume) }
            }
            .labelsHidden()
            .frame(width: 190)
        }
        .padding(.vertical, 8)
    }

    private var isMediaUnavailable: Bool {
        if case .unavailable = model.media { return true }
        return false
    }

    @ViewBuilder
    private var pauseMediaRow: some View {
        @Bindable var model = model
        if isMediaUnavailable {
            LabeledContent {
                Toggle("錄音時暫停媒體", isOn: .constant(false))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(true)
            } label: {
                HStack(spacing: 4) {
                    Text("錄音時暫停媒體").foregroundStyle(.secondary)
                    InfoButton("這台 Mac 的 macOS 不讓 App 控制別的 App 正在播放的音樂或影片，所以這項無法使用。")
                }
            }
        } else {
            Toggle(isOn: $model.prefs.pauseMedia) {
                HStack(spacing: 4) {
                    Text("錄音時暫停媒體")
                    InfoButton {
                        InfoText("錄音時暫停正在播放的音樂或影片，結束後再繼續播放。只會繼續播放被 Scriber 暫停的。")
                        InfoText("macOS 沒有正式開放這項功能，之後的系統更新可能讓它失效。")
                    }
                }
            }
        }
    }

    // MARK: Cues

    private enum CueMenuChoice: Hashable {
        case standard, none, custom, chooseFile
    }

    private func cueChoice(_ kind: CueKind) -> Binding<CueMenuChoice> {
        Binding(
            get: {
                switch model.prefs.cue(kind).effectiveSource {
                case .standard: .standard
                case .none: .none
                case .custom: .custom
                }
            },
            set: { choice in
                switch choice {
                case .standard: model.setCueSource(kind, .standard)
                case .none: model.setCueSource(kind, .none)
                case .custom: model.setCueSource(kind, .custom)
                case .chooseFile:
                    importTarget = kind
                    showImporter = true
                }
            }
        )
    }

    private func cueRow(_ kind: CueKind) -> some View {
        let setting = model.prefs.cue(kind)
        let note = model.cueNotes[kind]
        let title = kind == .start ? "開始" : "結束"
        return HStack(spacing: 8) {
            RowTitle(title, caption: note?.text, captionIsProblem: note?.isProblem ?? false)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Picker(title, selection: cueChoice(kind)) {
                    Text("預設").tag(CueMenuChoice.standard)
                    Text("無").tag(CueMenuChoice.none)
                    if setting.customFile != nil {
                        Text("自訂：\(setting.customName ?? "聲音檔")").tag(CueMenuChoice.custom)
                    }
                    Divider()
                    Text("選擇檔案…").tag(CueMenuChoice.chooseFile)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Button {
                    model.preview(kind)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(setting.effectiveSource == .none)
                .help("試聽")
                .accessibilityLabel("試聽\(title)提示音")
            }
        }
    }

    static func delayName(_ seconds: Double) -> String {
        seconds <= 0 ? "立即" : "\(Int(seconds)) 秒後"
    }
}

/// 麥克風: device menu, 測試 (only once microphone access is granted, never while dictating), and
/// under the title either the live meter or a live problem.
private struct MicrophoneRow: View {
    let model: AudioSettingsModel
    @Environment(EngineStatus.self) private var status

    var body: some View {
        let test = model.micTest
        LabeledContent {
            HStack(spacing: 10) {
                Picker("麥克風", selection: Binding(get: { model.prefs.inputDeviceUID }, set: { model.selectInput($0) })) {
                    Text(model.systemChoiceTitle).tag(String?.none)
                    Divider()
                    ForEach(model.devices) { device in
                        Text(device.menuTitle).tag(String?.some(device.uid))
                    }
                    if model.pinnedIsMissing {
                        Text(model.missingChoiceTitle).tag(model.prefs.inputDeviceUID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if status.micPermission == .granted, !model.devices.isEmpty {
                    Button(test.isRunning ? "停止" : "測試") { model.toggleMicTest() }
                        .buttonStyle(.bordered)
                        .disabled(status.phase != .idle)
                        .help(test.isRunning ? "停止測試" : "開麥克風 5 秒，看聲音有沒有進來")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("麥克風")
                if test.isRunning {
                    LevelMeter(level: test.level)
                } else if test.state == .failed {
                    caption("無法開啟麥克風")
                } else if model.pinnedIsMissing {
                    caption("未連接，錄音時改用系統預設")
                }
            }
        }
        .onAppear { model.activate() }
        .onDisappear { model.micTest.stop() }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.accentText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small segmented input meter (green, like the "on" dot).
struct LevelMeter: View {
    let level: Float
    var segments = 18

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Float(index) / Float(segments) < level ? Color.green : Color.primary.opacity(0.12))
                    .frame(width: 5, height: 7)
            }
        }
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityElement()
        .accessibilityLabel("輸入音量")
        .accessibilityValue("\(Int((level * 100).rounded()))%")
    }
}
