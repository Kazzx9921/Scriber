import Foundation

// CONTRACT FILE — shared by the app and the keyboard extension.
// Agents: do not change public signatures here without reporting it.

public enum AppGroup {
    public static let id = "group.com.geekaz.Scriber"
    /// URL scheme the keyboard uses to bring the app forward: scriber://session
    public static let urlScheme = "scriber"

    /// iOS: the App Group container shared by the app and the keyboard.
    /// macOS: there is a single process and no App Group, so this is
    /// `~/Library/Application Support/Scriber` (created on first use). Processes that are not an
    /// app bundle (the `swift test` runner, command-line tools) get a temporary folder instead, so
    /// tests never write into the Mac app's data.
    public static var containerURL: URL {
        #if os(macOS)
        return macContainerURL
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.temporaryDirectory
        #endif
    }

    /// iOS: the App Group suite. macOS: the app's standard defaults (no App Group; a suite named
    /// like the group would also make macOS ask about "data from other apps").
    public static var defaults: UserDefaults {
        #if os(macOS)
        return .standard
        #else
        return UserDefaults(suiteName: id) ?? .standard
        #endif
    }

    #if os(macOS)
    private static let macContainerURL: URL = {
        let fm = FileManager.default
        let folder: URL
        if Bundle.main.bundleURL.pathExtension == "app" {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            folder = support.appendingPathComponent("Scriber", isDirectory: true)
        } else {
            folder = fm.temporaryDirectory.appendingPathComponent("ScriberNonApp", isDirectory: true)
        }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
    #endif
}

public enum DictationMode: String, Codable, Sendable {
    /// Speak → cleaned-up text in the spoken language.
    case dictate
    /// Speak → text translated into `AppSettings.translateTarget`.
    case translate
    /// Speak an instruction → rewrite `DictationRequest.selectedText`.
    case edit
}

/// What the keyboard knows about the focused field. iOS never tells a keyboard which app it is in.
public enum FieldHint: String, Codable, Sendable {
    case general, email, url, search, chat
}

/// Sent keyboard → app with a `start` command.
///
/// Modes (docs/PRD-模式.md): `modeID` names the mode to run. When it is nil (or names a mode that
/// no longer exists) the pre-modes `mode` decides, as a compatibility layer: `.translate` → 翻譯,
/// `.edit` → 改寫, `.dictate` → the default mode (聽寫 unless the user picked another one).
/// All fields added for modes are optional, so requests written by older builds still decode.
public struct DictationRequest: Codable, Equatable, Sendable {
    public var id: String
    public var mode: DictationMode
    public var selectedText: String?
    public var fieldHint: FieldHint
    /// `DictationModeConfig.id` of the mode to run; nil = decided by `mode` (see above).
    public var modeID: String?
    /// Clipboard text, only when the mode's 情境感知 includes the clipboard. Never set it otherwise:
    /// requests are persisted briefly for the keyboard ↔ app handoff.
    public var clipboardText: String?
    /// Name of the app in front (macOS), only when the mode's 情境感知 includes it.
    public var appName: String?

    public init(id: String = UUID().uuidString, mode: DictationMode = .dictate,
                selectedText: String? = nil, fieldHint: FieldHint = .general,
                modeID: String? = nil, clipboardText: String? = nil, appName: String? = nil) {
        self.id = id; self.mode = mode; self.selectedText = selectedText; self.fieldHint = fieldHint
        self.modeID = modeID; self.clipboardText = clipboardText; self.appName = appName
    }

    /// Selected text with something other than whitespace in it.
    public var hasSelection: Bool {
        !(selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum SessionCommand: String, Codable, Sendable {
    case start   // begin capturing audio for `DictationRequest`
    case stop    // finish capturing, run the pipeline, publish the result
    case cancel  // discard the capture
}

public enum SessionPhase: String, Codable, Sendable {
    case idle, recording, processing, done, failed
}

/// Written app → keyboard. `heartbeat` is refreshed about once a second while the background session is alive.
public struct SessionState: Codable, Equatable, Sendable {
    public var heartbeat: Date
    public var phase: SessionPhase
    /// The request this phase refers to.
    public var requestID: String?
    /// Set when phase == .done. The keyboard inserts it exactly once per requestID.
    public var resultText: String?
    /// User-facing zh-Hant message, set when phase == .failed.
    public var errorMessage: String?
    /// When the session will end by itself.
    public var expiresAt: Date?

    public init(heartbeat: Date = .distantPast, phase: SessionPhase = .idle, requestID: String? = nil,
                resultText: String? = nil, errorMessage: String? = nil, expiresAt: Date? = nil) {
        self.heartbeat = heartbeat; self.phase = phase; self.requestID = requestID
        self.resultText = resultText; self.errorMessage = errorMessage; self.expiresAt = expiresAt
    }

    /// The app is considered alive if it wrote a heartbeat in the last few seconds.
    public func isAlive(now: Date = Date(), tolerance: TimeInterval = 3) -> Bool {
        now.timeIntervalSince(heartbeat) < tolerance
    }
}
