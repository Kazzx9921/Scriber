import Foundation

// Internal building blocks of SessionChannel: on-disk formats, the Darwin notification
// bridge and the shared level slot. Foundation/Darwin only — the keyboard links this module.

/// One command as written by the keyboard. `seq` is strictly increasing across the whole
/// lifetime of the install (see `SessionChannel.nextSequence`), so the app can process each
/// command exactly once no matter how many Darwin notifications arrive for it.
struct CommandRecord: Codable, Equatable, Sendable {
    var seq: Int64
    var command: SessionCommand
    var request: DictationRequest?
    var sentAt: Date
}

/// The command file holds the last few commands rather than only the newest one. Darwin
/// notifications coalesce, so a quick start → stop can reach the app as a single
/// notification; with a short log the app still sees both, in order.
struct CommandLog: Codable, Equatable, Sendable {
    static let capacity = 16
    var records: [CommandRecord] = []

    mutating func append(_ record: CommandRecord) {
        records.append(record)
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
    }
}

/// The state file. Wraps `SessionState` so channel-level extras can ride along without
/// touching the shared contract.
struct StateEnvelope: Codable, Equatable, Sendable {
    var state: SessionState
    /// True when `state.phase == .failed` and the app kept the audio, so sending `.stop`
    /// with the same request re-runs the pipeline instead of asking the user to speak again.
    var retryable: Bool
    /// When the significant part last changed (set by `SessionChannel.writeState`). Optional so
    /// files from older builds still decode. The keyboard measures a result's age from it.
    var changedAt: Date?

    init(state: SessionState, retryable: Bool, changedAt: Date? = nil) {
        self.state = state; self.retryable = retryable; self.changedAt = changedAt
    }

    /// Everything the keyboard reacts to. The heartbeat is excluded on purpose: it changes
    /// every second and is read on demand, so it must not wake the keyboard.
    var significant: StateEnvelope {
        var copy = self
        copy.state.heartbeat = .distantPast
        copy.changedAt = nil
        return copy
    }
}

enum WireCoding {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .deferredToDate // exact Double round trip
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder().encode(value)
        #if os(iOS)
        // The session must keep working on the lock screen, after the first unlock.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(type, from: data)
    }
}

// MARK: - Darwin notifications

/// Thin wrapper over the Darwin notify center. The observer pointer is the owner object,
/// so the C callback can find its way back without a global registry.
enum DarwinBridge {
    static var center: CFNotificationCenter { CFNotificationCenterGetDarwinNotifyCenter() }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    static func addObserver(_ owner: SessionChannel, name: String) {
        let observer = Unmanaged.passUnretained(owner).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let channel = Unmanaged<SessionChannel>.fromOpaque(observer).takeUnretainedValue()
            channel.didReceiveDarwinNotification(name.rawValue as String)
        }, name as CFString, nil, .deliverImmediately)
    }

    static func removeAll(_ owner: SessionChannel) {
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(owner).toOpaque())
    }
}

// MARK: - Level slot

/// The input level lives in an 8-byte file that is rewritten in place with `pwrite` and read
/// with `pread`: [Float32 level][UInt32 millisecond stamp], little endian.
///
/// Why not JSON + atomic write: at 20–30 Hz that is a temp file and a rename per update.
/// Why not shared UserDefaults: cross-process reads go through cfprefsd and can lag.
/// In-place writes on a kept-open descriptor are one syscall each, land in the shared page
/// cache (both processes see them immediately) and only ever dirty a single page.
/// The app writes only while recording, and the keyboard reads only while it draws the
/// waveform, so nothing runs when idle.
final class LevelSlot: @unchecked Sendable {
    /// A level older than this is treated as silence (the recorder stopped or died).
    static let staleAfterMillis: UInt32 = 600

    private let url: URL
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var fdIsWritable = false

    init(url: URL) { self.url = url }
    deinit { if fd >= 0 { close(fd) } }

    static func nowMillis() -> UInt32 {
        UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000))
    }

    func write(_ level: Float, stamp: UInt32 = LevelSlot.nowMillis()) {
        lock.lock(); defer { lock.unlock() }
        guard let fd = descriptor(writable: true) else { return }
        var bytes = (min(max(level, 0), 1).bitPattern.littleEndian, stamp.littleEndian)
        _ = withUnsafeBytes(of: &bytes) { pwrite(fd, $0.baseAddress, 8, 0) }
    }

    func read(now: UInt32 = LevelSlot.nowMillis()) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard let fd = descriptor(writable: false) else { return 0 }
        var bytes: (UInt32, UInt32) = (0, 0)
        let n = withUnsafeMutableBytes(of: &bytes) { pread(fd, $0.baseAddress, 8, 0) }
        guard n == 8 else { return 0 }
        let stamp = UInt32(littleEndian: bytes.1)
        guard now &- stamp < Self.staleAfterMillis else { return 0 }
        let level = Float(bitPattern: UInt32(littleEndian: bytes.0))
        return level.isFinite ? min(max(level, 0), 1) : 0
    }

    /// Opens lazily and keeps the descriptor. A failed open (file not created yet, or no
    /// App Group access) is retried on the next call.
    private func descriptor(writable: Bool) -> Int32? {
        if fd >= 0, fdIsWritable || !writable { return fd }
        if fd >= 0 { close(fd); fd = -1 }
        let flags = writable ? (O_RDWR | O_CREAT) : O_RDONLY
        let opened = open(url.path, flags, 0o644)
        guard opened >= 0 else { return nil }
        fd = opened
        fdIsWritable = writable
        return fd
    }
}
