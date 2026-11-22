import Foundation

/// The two recording cues.
enum CueKind: String, CaseIterable, Sendable {
    case start, stop
}

/// What a cue plays: the bundled sound (`Mac/Resources/Sounds`), nothing, or a file the user picked
/// (copied into Application Support, see `CustomCueFiles`).
enum CueSource: String, Equatable, Sendable {
    case standard = "default"
    case none
    case custom
}

struct CueSetting: Equatable, Sendable {
    var source: CueSource = .standard
    /// File name inside `CustomCueFiles.directory`, kept while another source is selected so the
    /// user can switch back.
    var customFile: String?
    /// The picked file's original name, for the menu.
    var customName: String?

    /// `.custom` without a file behaves like `.standard`.
    var effectiveSource: CueSource {
        source == .custom && customFile == nil ? .standard : source
    }
}

/// 設定 → 音訊, stored in the Mac app's standard defaults (`AppGroup.defaults` on macOS), next to
/// `mac.restoreClipboard`. Read fresh at the start of every recording, so a change applies to the
/// next one.
struct AudioPreferences: Equatable, Sendable {
    /// nil: follow the system's input device. Otherwise the pinned device's Core Audio UID (stable
    /// across reconnects), kept while the device is away so it is used again when it returns.
    var inputDeviceUID: String?
    /// The pinned device's last seen name, for the menu while it is not connected.
    var inputDeviceName: String?
    var startCue = CueSetting()
    var stopCue = CueSetting()
    /// `NSSound.volume` (relative to the system output volume).
    var cueVolume: Double = Self.defaultCueVolume
    /// Mute the default output device while recording.
    var muteOutput = false
    /// Pause the now-playing app while recording (only where `MediaAvailability` allows).
    var pauseMedia = false
    /// Seconds between the end of a recording and resuming what was paused.
    var resumeDelay: Double = 1

    static let defaultCueVolume = 0.6
    static let cueVolumeRange: ClosedRange<Double> = 0.1...1
    static let resumeDelayChoices: [Double] = [0, 1, 2, 3, 5]

    enum Key {
        static let inputDeviceUID = "mac.audio.inputDeviceUID"
        static let inputDeviceName = "mac.audio.inputDeviceName"
        static let cueVolume = "mac.audio.cueVolume"
        static let muteOutput = "mac.audio.muteOutput"
        static let pauseMedia = "mac.audio.pauseMedia"
        static let resumeDelay = "mac.audio.resumeDelay"

        static func cueSource(_ kind: CueKind) -> String { "mac.audio.cue.\(kind.rawValue)" }
        static func cueFile(_ kind: CueKind) -> String { "mac.audio.cue.\(kind.rawValue).file" }
        static func cueName(_ kind: CueKind) -> String { "mac.audio.cue.\(kind.rawValue).name" }

        /// The single on/off switch before per-cue choices (`SoundCues.enabledKey`, on by default).
        static let legacyCues = "mac.soundCues"
    }

    func cue(_ kind: CueKind) -> CueSetting {
        kind == .start ? startCue : stopCue
    }

    mutating func setCue(_ kind: CueKind, _ setting: CueSetting) {
        if kind == .start { startCue = setting } else { stopCue = setting }
    }

    // MARK: Storage

    static func load(from defaults: UserDefaults) -> AudioPreferences {
        var prefs = AudioPreferences()
        prefs.inputDeviceUID = nonEmpty(defaults.string(forKey: Key.inputDeviceUID))
        prefs.inputDeviceName = nonEmpty(defaults.string(forKey: Key.inputDeviceName))
        for kind in CueKind.allCases {
            var cue = CueSetting()
            cue.source = defaults.string(forKey: Key.cueSource(kind)).flatMap(CueSource.init(rawValue:)) ?? .standard
            cue.customFile = nonEmpty(defaults.string(forKey: Key.cueFile(kind)))
            cue.customName = nonEmpty(defaults.string(forKey: Key.cueName(kind)))
            prefs.setCue(kind, cue)
        }
        if let volume = defaults.object(forKey: Key.cueVolume) as? Double, volume.isFinite {
            prefs.cueVolume = min(max(volume, cueVolumeRange.lowerBound), cueVolumeRange.upperBound)
        }
        prefs.muteOutput = defaults.object(forKey: Key.muteOutput) as? Bool ?? false
        prefs.pauseMedia = defaults.object(forKey: Key.pauseMedia) as? Bool ?? false
        if let delay = defaults.object(forKey: Key.resumeDelay) as? Double, resumeDelayChoices.contains(delay) {
            prefs.resumeDelay = delay
        }
        return prefs
    }

    func save(to defaults: UserDefaults) {
        defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID)
        defaults.set(inputDeviceName, forKey: Key.inputDeviceName)
        for kind in CueKind.allCases {
            let cue = cue(kind)
            defaults.set(cue.source.rawValue, forKey: Key.cueSource(kind))
            defaults.set(cue.customFile, forKey: Key.cueFile(kind))
            defaults.set(cue.customName, forKey: Key.cueName(kind))
        }
        defaults.set(cueVolume, forKey: Key.cueVolume)
        defaults.set(muteOutput, forKey: Key.muteOutput)
        defaults.set(pauseMedia, forKey: Key.pauseMedia)
        defaults.set(resumeDelay, forKey: Key.resumeDelay)
    }

    /// The old single switch → per-cue choices: off means both cues 無, on keeps the defaults.
    /// Per-cue values already stored win. Removes the old key, so it runs once. Returns a log line
    /// when something was migrated.
    @discardableResult
    static func migrate(_ defaults: UserDefaults) -> String? {
        guard let old = defaults.object(forKey: Key.legacyCues) else { return nil }
        let enabled = (old as? Bool) ?? (old as? NSNumber)?.boolValue ?? true
        var changed: [String] = []
        if !enabled {
            for kind in CueKind.allCases where defaults.object(forKey: Key.cueSource(kind)) == nil {
                defaults.set(CueSource.none.rawValue, forKey: Key.cueSource(kind))
                changed.append(kind.rawValue)
            }
        }
        defaults.removeObject(forKey: Key.legacyCues)
        return "migrated soundCues=\(enabled) → \(changed.isEmpty ? "unchanged" : "none for \(changed.joined(separator: ","))")"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: Log

    /// Content-free: the pinned device only as a short hash of its UID, never its name.
    var logDescription: String {
        let input = inputDeviceUID.map { "pinned(\(AudioLog.tag($0)))" } ?? "system"
        return "input=\(input) cueStart=\(startCue.effectiveSource.rawValue) cueStop=\(stopCue.effectiveSource.rawValue) "
            + "cueVolume=\(String(format: "%.2f", cueVolume)) mute=\(muteOutput) pauseMedia=\(pauseMedia) "
            + "resumeDelay=\(Int(resumeDelay))s"
    }
}

/// Short, stable, content-free tokens for audio log lines.
enum AudioLog {
    /// "dev#3f9a1c": FNV-1a of a device UID (stable across launches, unlike `hashValue`).
    static func tag(_ uid: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in uid.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return "dev#" + String(format: "%06x", hash & 0xFF_FFFF)
    }

    /// `0` or `-10851` or `2003332927('what')`.
    static func status(_ status: Int32) -> String {
        let code = UInt32(bitPattern: status)
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        guard status != 0, bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
              let text = String(bytes: bytes, encoding: .ascii) else { return "\(status)" }
        return "\(status)('\(text)')"
    }
}
