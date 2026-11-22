import AppKit
import ScriberShared

/// Short audio cues for "started listening" and "stopped listening", so the user knows the
/// hotkey registered without looking at the screen.
///
/// Each cue is 預設 (the bundled `cue-start` / `cue-stop` in Mac/Resources/Sounds — see NOTICE.md
/// there for their origin and license), 無, or 自訂 (a file the user picked, copied into
/// Application Support by `CustomCueFiles`). A custom file that has gone missing plays the default.
/// Volume is `NSSound.volume`, which scales relative to the system output volume (it cannot be
/// louder than the system volume allows, and is silent when the output is muted).
///
/// When the cues play relative to the microphone, muting and media is decided by
/// `RecordingAudioSession`.
@MainActor
final class SoundCues: CuePort {
    static let shared = SoundCues()

    let files = CustomCueFiles()
    private var cache: [String: NSSound] = [:]
    private var missingLogged: Set<String> = []

    /// Loads the default sounds ahead of time so the first cue is not delayed.
    func prepare() {
        for kind in CueKind.allCases { _ = bundled(kind) }
    }

    func play(_ kind: CueKind, prefs: AudioPreferences) -> TimeInterval? {
        guard let sound = sound(kind, prefs.cue(kind)) else { return nil }
        if sound.isPlaying { sound.stop() }
        sound.volume = Float(prefs.cueVolume)
        guard sound.play() else {
            DiagLog.log("audio", "cue \(kind.rawValue) did not play")
            return nil
        }
        return sound.duration
    }

    /// 試聽 in settings: the cue as currently set (nothing for 無).
    @discardableResult
    func preview(_ kind: CueKind, prefs: AudioPreferences) -> Bool {
        play(kind, prefs: prefs) != nil
    }

    /// Length of the cue as set, without playing it (nil for 無 or unreadable).
    func duration(_ kind: CueKind, prefs: AudioPreferences) -> TimeInterval? {
        sound(kind, prefs.cue(kind))?.duration
    }

    /// Whether a picked file can be played (NSSound can be pickier than the duration check).
    func canPlay(_ url: URL) -> Bool {
        NSSound(contentsOf: url, byReference: false) != nil
    }

    private func sound(_ kind: CueKind, _ setting: CueSetting) -> NSSound? {
        switch setting.effectiveSource {
        case .none:
            return nil
        case .standard:
            return bundled(kind)
        case .custom:
            guard let name = setting.customFile, files.exists(name) else {
                if missingLogged.insert(kind.rawValue).inserted {
                    DiagLog.log("audio", "cue \(kind.rawValue) custom file missing → default")
                }
                return bundled(kind)
            }
            if let cached = cache[name] { return cached }
            guard let sound = NSSound(contentsOf: files.url(for: name), byReference: false) else {
                DiagLog.log("audio", "cue \(kind.rawValue) custom file unreadable → default")
                return bundled(kind)
            }
            cache[name] = sound
            return sound
        }
    }

    // The cue files live in Mac/Resources/Sounds. Any `cue-start` / `cue-stop` audio file NSSound
    // can read works.
    private func bundled(_ kind: CueKind) -> NSSound? {
        let name = "cue-\(kind.rawValue)"
        if let cached = cache[name] { return cached }
        for ext in ["mp3", "wav", "aiff", "m4a", "caf"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext)
                    ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Sounds"),
                  let sound = NSSound(contentsOf: url, byReference: false) else { continue }
            cache[name] = sound
            return sound
        }
        return nil
    }

    /// Drops a replaced custom file from the cache.
    func forget(_ fileName: String?) {
        guard let fileName else { return }
        cache[fileName] = nil
    }
}
