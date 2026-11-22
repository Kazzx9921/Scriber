import CoreAudio
import Foundation
import Observation
import ScriberShared

/// State behind 設定 → 音訊. The preferences themselves live in the defaults (`AudioPreferences`);
/// the dictation engine reads them fresh at every recording, so this model only edits them.
///
/// `shared` is the live instance (Core Audio device list with live updates, media availability
/// probed once, the custom cue files). `init(sample:)` is detached state for snapshot renders:
/// it never touches the defaults, Core Audio, the microphone or a sound.
@MainActor
@Observable
final class AudioSettingsModel {
    static let shared = AudioSettingsModel()

    /// A short line under a cue row right after picking a file.
    struct CueNote: Equatable {
        var text: String
        var isProblem: Bool
    }

    var prefs: AudioPreferences {
        didSet {
            guard prefs != oldValue, isLive else { return }
            prefs.save(to: defaults)
            DiagLog.log("app", "settings audio \(prefs.logDescription)")
        }
    }

    private(set) var devices: [AudioInputDevice] = []
    private(set) var defaultInputID: AudioDeviceID?
    private(set) var media: MediaAvailability = .unknown
    private(set) var cueNotes: [CueKind: CueNote] = [:]
    let micTest: MicLevelTest

    @ObservationIgnored let isLive: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var noteWork: [CueKind: DispatchWorkItem] = [:]
    @ObservationIgnored private var mediaProbe: MediaRemoteScript?

    private init() {
        isLive = true
        defaults = AppGroup.defaults
        if let line = AudioPreferences.migrate(defaults) { DiagLog.log("app", "settings audio \(line)") }
        prefs = AudioPreferences.load(from: defaults)
        micTest = MicLevelTest()
    }

    /// Detached sample state for snapshot renders.
    struct Sample {
        var prefs = AudioPreferences()
        var devices: [AudioInputDevice] = Sample.devices
        var defaultInputID: AudioDeviceID? = 10
        var media: MediaAvailability = .available
        var micTest: MicLevelTest.State = .idle
        var micLevel: Float = 0
        var cueNotes: [CueKind: CueNote] = [:]

        static let devices = [
            AudioInputDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro的麥克風", transport: .builtIn, inputChannels: 1),
            AudioInputDevice(id: 11, uid: "airpods-sample", name: "AirPods Pro", transport: .bluetooth, inputChannels: 1),
            AudioInputDevice(id: 12, uid: "yeti-sample", name: "Yeti Stereo Microphone", transport: .usb, inputChannels: 2),
        ]
    }

    init(sample: Sample) {
        isLive = false
        defaults = UserDefaults(suiteName: "scriber-snapshot-audio-\(UUID().uuidString)") ?? .standard
        prefs = sample.prefs
        devices = sample.devices
        defaultInputID = sample.defaultInputID
        media = sample.media
        cueNotes = sample.cueNotes
        micTest = MicLevelTest(sample: sample.micTest, level: sample.micLevel)
    }

    // MARK: Derived

    var defaultInput: AudioInputDevice? { devices.first { $0.id == defaultInputID } }

    var pinnedDevice: AudioInputDevice? {
        guard let uid = prefs.inputDeviceUID else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// A microphone is chosen but not connected: recordings use the system default meanwhile.
    var pinnedIsMissing: Bool { prefs.inputDeviceUID != nil && pinnedDevice == nil }

    var systemChoiceTitle: String {
        defaultInput.map { "跟隨系統（\($0.name)）" } ?? "跟隨系統"
    }

    var missingChoiceTitle: String {
        "\(prefs.inputDeviceName ?? "指定的麥克風")（未連接）"
    }

    /// Collapsed 提示音 row.
    var cueSummary: String {
        switch (prefs.startCue.effectiveSource, prefs.stopCue.effectiveSource) {
        case (.standard, .standard): "預設"
        case (.none, .none): "關閉"
        case (.none, _): "只有結束"
        case (_, .none): "只有開始"
        default: "自訂"
        }
    }

    var anyCuePlays: Bool {
        prefs.startCue.effectiveSource != .none || prefs.stopCue.effectiveSource != .none
    }

    // MARK: Live updates

    /// The settings page appeared: read devices, follow changes, find out whether media can be paused.
    func activate() {
        guard isLive else { return }
        refreshDevices()
        if observer == nil {
            AudioDeviceMonitor.shared.start()
            observer = NotificationCenter.default.addObserver(forName: .scriberAudioDevicesChanged, object: nil,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            }
        }
        // Re-checked on every visit until it works (a timeout once should not hide it for good).
        if media != .available, mediaProbe == nil {
            let probe = MediaRemoteScript()
            mediaProbe = probe
            probe.probe { [weak self] availability in
                guard let self else { return }
                self.media = availability
                self.mediaProbe = nil
                DiagLog.log("audio", "media control probe → \(Self.describe(availability)) macOS=\(MacDiag.osVersion)")
            }
        }
        // A custom file deleted behind the app's back: back to the default sound.
        for kind in CueKind.allCases {
            let cue = prefs.cue(kind)
            if cue.customFile != nil, !SoundCues.shared.files.exists(cue.customFile) {
                DiagLog.log("audio", "cue \(kind.rawValue) custom file missing → default")
                prefs.setCue(kind, CueSetting())
            }
        }
    }

    func refreshDevices() {
        guard isLive else { return }
        let list = CoreAudioQuery.inputDevices()
        let defaultID = CoreAudioQuery.defaultInputDeviceID()
        if list != devices { devices = list }
        if defaultID != defaultInputID { defaultInputID = defaultID }
        // Keep the pinned device's name current for when it is away.
        if let pinned = pinnedDevice, pinned.name != prefs.inputDeviceName {
            prefs.inputDeviceName = pinned.name
        }
    }

    static func describe(_ availability: MediaAvailability) -> String {
        switch availability {
        case .unknown: "unknown"
        case .available: "available"
        case .unavailable(let reason): "unavailable(\(reason))"
        }
    }

    // MARK: Microphone

    func selectInput(_ uid: String?) {
        guard uid != prefs.inputDeviceUID else { return }
        if micTest.isRunning { micTest.stop() }
        var next = prefs
        next.inputDeviceUID = uid
        next.inputDeviceName = uid.flatMap { id in devices.first { $0.uid == id }?.name }
        prefs = next
    }

    func toggleMicTest() {
        if micTest.isRunning {
            micTest.stop()
        } else {
            micTest.start(pinnedUID: prefs.inputDeviceUID)
        }
    }

    // MARK: Cues

    func setCueSource(_ kind: CueKind, _ source: CueSource) {
        var cue = prefs.cue(kind)
        guard cue.effectiveSource != source else { return }
        cue.source = source
        prefs.setCue(kind, cue)
        setNote(nil, for: kind)
    }

    func preview(_ kind: CueKind) {
        guard isLive else { return }
        SoundCues.shared.preview(kind, prefs: prefs)
    }

    /// Slider released: store and let the user hear it.
    func commitVolume(_ value: Double) {
        let clamped = min(max(value, AudioPreferences.cueVolumeRange.lowerBound), AudioPreferences.cueVolumeRange.upperBound)
        guard abs(clamped - prefs.cueVolume) > 0.001 else { return }
        prefs.cueVolume = clamped
        preview(prefs.startCue.effectiveSource != .none ? .start : .stop)
    }

    /// A file picked with 選擇檔案…: checked, copied in, selected, played once.
    func importCue(_ kind: CueKind, from url: URL) {
        guard isLive else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let cues = SoundCues.shared
        let ext = url.pathExtension.lowercased()
        let imported: CustomCueFiles.Imported
        do {
            imported = try cues.files.importFile(url, for: kind)
        } catch CustomCueFiles.ImportError.rejected(let check) {
            DiagLog.log("audio", "cue \(kind.rawValue) custom file refused \(check.logName) ext=\(ext)")
            setNote(CueNote(text: Self.message(for: check), isProblem: true), for: kind)
            return
        } catch {
            DiagLog.log("audio", "cue \(kind.rawValue) custom file copy failed ext=\(ext)")
            setNote(CueNote(text: "無法加入這個檔案", isProblem: true), for: kind)
            return
        }
        guard cues.canPlay(cues.files.url(for: imported.fileName)) else {
            cues.files.remove(imported.fileName)
            DiagLog.log("audio", "cue \(kind.rawValue) custom file not playable ext=\(ext)")
            setNote(CueNote(text: Self.message(for: .unreadable), isProblem: true), for: kind)
            return
        }
        let previous = prefs.cue(kind).customFile
        prefs.setCue(kind, CueSetting(source: .custom, customFile: imported.fileName, customName: imported.displayName))
        if let previous, previous != imported.fileName {
            cues.forget(previous)
            cues.files.remove(previous)
        }
        DiagLog.log("audio", "cue \(kind.rawValue) custom file set \(imported.check.logName) ext=\(ext)")
        if case .long(let seconds) = imported.check {
            setNote(CueNote(text: "有 \(String(format: "%.1f", seconds)) 秒，可能太長", isProblem: false), for: kind)
        } else {
            setNote(nil, for: kind)
        }
        preview(kind)
    }

    static func message(for check: CustomCueFiles.Check) -> String {
        switch check {
        case .tooLong: "超過 \(Int(CustomCueFiles.maxSeconds)) 秒，請換短一點的"
        case .tooBig: "檔案太大"
        case .unreadable: "讀不到這個聲音檔"
        case .ok, .long: ""
        }
    }

    private func setNote(_ note: CueNote?, for kind: CueKind) {
        noteWork[kind]?.cancel()
        cueNotes[kind] = note
        guard note != nil, isLive else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.cueNotes[kind] = nil }
        }
        noteWork[kind] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}
