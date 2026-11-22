import AppKit
import SwiftUI
import XCTest

/// 設定 → 音訊 in each state, light and dark (detached sample model: no Core Audio, no microphone,
/// no sound, no defaults). Run with `xcodebuild test -scheme ScriberMacSnapshots`.
@MainActor
final class AudioSettingsSnapshotTests: XCTestCase {
    private func section(_ sample: AudioSettingsModel.Sample, status: EngineStatus? = nil,
                         showsCues: Bool = false) -> some View {
        Form {
            AudioSettingsSection(model: AudioSettingsModel(sample: sample), showsCues: showsCues)
        }
        .formStyle(.grouped)
        .environment(status ?? Sample.status())
        .environment(Sample.settings())
    }

    private let collapsed = CGSize(width: 700, height: 300)
    private let expanded = CGSize(width: 700, height: 470)

    func testAudioSection() throws {
        // 1. Fresh: 跟隨系統, everything off, 提示音 closed.
        try SnapshotRenderer.renderBoth("12-audio-1-default", size: collapsed, chrome: false) {
            section(.init())
        }

        // 2. Everything on: a pinned USB microphone, mute, pause with its delay, 提示音 open with a
        //    custom stop sound.
        var allOn = AudioSettingsModel.Sample()
        allOn.prefs.inputDeviceUID = "yeti-sample"
        allOn.prefs.inputDeviceName = "Yeti Stereo Microphone"
        allOn.prefs.muteOutput = true
        allOn.prefs.pauseMedia = true
        allOn.prefs.resumeDelay = 2
        allOn.prefs.stopCue = CueSetting(source: .custom, customFile: "stop-1.wav", customName: "Glass")
        allOn.prefs.cueVolume = 0.45
        try SnapshotRenderer.renderBoth("12-audio-2-all-on-cues-open", size: expanded, chrome: false) {
            section(allOn, showsCues: true)
        }

        // 3. The pinned microphone is unplugged; media control is not possible on this macOS;
        //    both cues off.
        var missing = AudioSettingsModel.Sample()
        missing.prefs.inputDeviceUID = "away-sample"
        missing.prefs.inputDeviceName = "Shure MV7"
        missing.media = .unavailable("api")
        missing.prefs.pauseMedia = true
        missing.prefs.startCue = CueSetting(source: .none)
        missing.prefs.stopCue = CueSetting(source: .none)
        try SnapshotRenderer.renderBoth("12-audio-3-missing-mic-no-media", size: collapsed, chrome: false) {
            section(missing)
        }
        try SnapshotRenderer.renderBoth("12-audio-3b-cues-off-open", size: expanded, chrome: false) {
            section(missing, showsCues: true)
        }

        // 4. 測試 running.
        var testing = AudioSettingsModel.Sample()
        testing.micTest = .running
        testing.micLevel = 0.55
        try SnapshotRenderer.renderBoth("12-audio-4-mic-test", size: collapsed, chrome: false) {
            section(testing)
        }

        // 5. Just picked files: one refused, one accepted with a warning.
        var notes = AudioSettingsModel.Sample()
        notes.prefs.stopCue = CueSetting(source: .custom, customFile: "stop-2.m4a", customName: "長長的鈴聲")
        notes.cueNotes = [
            .start: .init(text: AudioSettingsModel.message(for: .tooLong(7.5)), isProblem: true),
            .stop: .init(text: "有 3.2 秒，可能太長", isProblem: false),
        ]
        try SnapshotRenderer.renderBoth("12-audio-5-cue-file-notes", size: expanded, chrome: false) {
            section(notes, showsCues: true)
        }

        // 6. Microphone access not granted yet: no 測試 (it would prompt). 7. 測試 could not start.
        try SnapshotRenderer.renderBoth("12-audio-6-no-mic-permission", size: collapsed, chrome: false) {
            section(.init(), status: Sample.status(mic: .notDetermined))
        }
        var failed = AudioSettingsModel.Sample()
        failed.micTest = .failed
        try SnapshotRenderer.renderBoth("12-audio-7-mic-test-failed", size: collapsed, chrome: false) {
            section(failed)
        }

        // 8. While dictating: 測試 disabled. 9. No devices at all (Mac mini without a microphone).
        try SnapshotRenderer.renderBoth("12-audio-8-while-recording", size: collapsed, chrome: false) {
            section(.init(), status: Sample.status(phase: .recording))
        }
        var none = AudioSettingsModel.Sample()
        none.devices = []
        none.defaultInputID = nil
        try SnapshotRenderer.renderBoth("12-audio-9-no-devices", size: collapsed, chrome: false) {
            section(none)
        }
    }

    /// The explanations behind the "?" buttons (popovers cannot be captured, so drawn alone).
    func testAudioExplanations() throws {
        try SnapshotRenderer.renderBoth("12-audio-info", size: CGSize(width: 332, height: 330), chrome: false) {
            VStack(alignment: .leading, spacing: 10) { AudioSettingsSection.explanations }
            .font(.callout).frame(width: 300, alignment: .leading).padding(16)
        }
    }

    /// The whole settings page, tall enough to show 音訊 between 標點符號 and 一般.
    func testSettingsPageWithAudio() throws {
        let data = Sample.sources(history: Sample.history([]), stats: Sample.stats)
        try SnapshotRenderer.renderBoth("06-settings-8-audio-in-page", size: CGSize(width: 980, height: 2500)) {
            mainWindow(.settings, settings: Sample.settings(keys: [.elevenLabs]), status: Sample.status(), data: data)
        }
    }
}
