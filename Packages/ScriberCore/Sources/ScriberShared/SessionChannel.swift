import Foundation

// CONTRACT FILE — implementation owned by the "session + keyboard" agent.
// Transport: Darwin notifications (no payload) as the "something changed" signal,
// payloads as small files inside the App Group container.
//
// Files (in <AppGroup>/Session/):
//   commands.json  keyboard → app. A short log of `CommandRecord`s with a strictly increasing `seq`.
//   state.json     app → keyboard. `StateEnvelope` (SessionState + retryable flag), atomic writes.
//   level.bin      app → keyboard. 8 bytes rewritten in place while recording (see `LevelSlot`).
//
// Semantics the two sides agree on:
//   - `.start` carries the request. Commands are applied once per `seq`; a duplicated or
//     coalesced notification cannot double-start, and a `.start` older than
//     `startCommandMaxAge` is ignored (it was meant for a moment that has passed).
//   - `.stop` may carry the request again with an updated `mode` (slide-up translate is only
//     known at release). The app uses that mode.
//   - `.stop` for a request that is not recording but whose audio was kept after a network
//     failure (`readRetryable()` == true) re-runs the pipeline on the kept audio: that is retry.
//   - `.cancel` discards the capture, or abandons processing.
//   - The state notification fires only when something other than the heartbeat changes.
//     Liveness is read on demand with `readState().isAlive()`.

/// Two-way channel between the keyboard extension and the background app.
/// Create one instance per process and keep it alive.
public final class SessionChannel: @unchecked Sendable {
    /// A `.start` that sat in the log longer than this is not acted on.
    public static let startCommandMaxAge: TimeInterval = 5

    private let directory: URL
    private let commandName: String
    private let stateName: String
    private let levelSlot: LevelSlot

    private let lock = NSLock()
    // Guarded by `lock`.
    private var stateHandlers: [(SessionState) -> Void] = []
    private var commandHandlers: [(SessionCommand, DictationRequest?) -> Void] = []
    private var observingState = false
    private var observingCommands = false
    private var lastHandledSeq: Int64 = 0
    private var lastSentSeq: Int64 = 0
    private var lastPostedSignificant: StateEnvelope?
    private var lastChangedAt: Date?
    private var lastDeliveredSignificant: StateEnvelope?

    public convenience init() {
        self.init(directory: AppGroup.containerURL.appendingPathComponent("Session", isDirectory: true),
                  namespace: "com.geekaz.Scriber.session")
    }

    /// For tests: an isolated directory and Darwin namespace.
    public init(directory: URL, namespace: String) {
        self.directory = directory
        self.commandName = namespace + ".command"
        self.stateName = namespace + ".state"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.levelSlot = LevelSlot(url: directory.appendingPathComponent("level.bin"))
    }

    // MARK: Launch request
    //
    // The app is not running (or is suspended) when the keyboard opens it, so a Darwin
    // notification would be lost. The keyboard leaves the request in a file and the app
    // picks it up as soon as its microphone is running.

    private struct LaunchRecord: Codable {
        var request: DictationRequest
        var sentAt: Date
    }

    private var launchURL: URL { directory.appendingPathComponent("launch.json") }

    /// Keyboard side: the request the app should start recording as soon as it is opened.
    public func writeLaunchRequest(_ request: DictationRequest) {
        try? WireCoding.write(LaunchRecord(request: request, sentAt: Date()), to: launchURL)
    }

    /// App side: returns the pending launch request once, if it is recent enough.
    public func takeLaunchRequest(maxAge: TimeInterval = 20) -> DictationRequest? {
        guard let record = WireCoding.read(LaunchRecord.self, from: launchURL) else { return nil }
        try? FileManager.default.removeItem(at: launchURL)
        guard Date().timeIntervalSince(record.sentAt) < maxAge else { return nil }
        return record.request
    }

    /// Keyboard side: the launch request still waiting for the app (not taken yet), without
    /// consuming it. Nil once the app took it (or nothing was written).
    public func peekLaunchRequest() -> (id: String, sentAt: Date)? {
        WireCoding.read(LaunchRecord.self, from: launchURL).map { ($0.request.id, $0.sentAt) }
    }

    /// Keyboard side: takes back a launch request the app has not picked up (the keyboard gave
    /// up waiting, or recorded by itself), so a later app start does not record for it.
    public func withdrawLaunchRequest(id: String) {
        guard let record = WireCoding.read(LaunchRecord.self, from: launchURL), record.request.id == id else { return }
        try? FileManager.default.removeItem(at: launchURL)
    }

    // MARK: Microphone permission mirror
    //
    // The keyboard decides whether it may record by itself (in-keyboard capture) before it
    // tries, and a keyboard extension cannot reliably ask for the containing app's microphone
    // permission. The app mirrors it into the App Group defaults whenever it becomes active
    // (App/Engine/MicPermissionMirror.m writes the same key and values).

    /// App Group defaults key; values "granted" / "denied" / "undetermined".
    public static let appMicrophonePermissionKey = "app.microphonePermission"

    /// App side.
    public static func publishAppMicrophonePermission(_ value: String) {
        let defaults = AppGroup.defaults
        if defaults.string(forKey: appMicrophonePermissionKey) != value {
            defaults.set(value, forKey: appMicrophonePermissionKey)
        }
    }

    /// Keyboard side: what the app last published, nil if it never did.
    public static func readAppMicrophonePermission() -> String? {
        AppGroup.defaults.string(forKey: appMicrophonePermissionKey)
    }

    deinit {
        DarwinBridge.removeAll(self)
    }

    var commandsURL: URL { directory.appendingPathComponent("commands.json") }
    var stateURL: URL { directory.appendingPathComponent("state.json") }

    // MARK: Keyboard side

    /// Send a command to the app. `request` is required for `.start`.
    public func send(_ command: SessionCommand, request: DictationRequest? = nil) {
        send(command, request: request, sentAt: Date(), post: true)
    }

    /// Latest state written by the app (reads the file; cheap).
    public func readState() -> SessionState {
        readEnvelope()?.state ?? SessionState()
    }

    /// When the app last changed something other than the heartbeat (phase, request, result…).
    /// Nil for state files written before this field existed.
    public func readStateChangedAt() -> Date? {
        readEnvelope()?.changedAt
    }

    /// Whether the latest `.failed` state can be retried with the audio the app kept.
    public func readRetryable() -> Bool {
        guard let envelope = readEnvelope() else { return false }
        return envelope.retryable && envelope.state.phase == .failed
    }

    /// Called on the main queue whenever the app publishes a new state.
    public func observeState(_ handler: @escaping (SessionState) -> Void) {
        lock.lock()
        stateHandlers.append(handler)
        let shouldRegister = !observingState
        observingState = true
        lock.unlock()
        if shouldRegister { DarwinBridge.addObserver(self, name: stateName) }
    }

    /// Latest input level 0...1 while recording, for the waveform. Poll at display rate.
    public func readLevel() -> Float {
        levelSlot.read()
    }

    // MARK: App side

    /// Called on the main queue when the keyboard sends a command.
    /// Commands already in the log when observation starts are treated as handled.
    public func observeCommands(_ handler: @escaping (SessionCommand, DictationRequest?) -> Void) {
        let existing = readCommandLog().records.last?.seq ?? 0
        lock.lock()
        commandHandlers.append(handler)
        let shouldRegister = !observingCommands
        if shouldRegister { lastHandledSeq = max(lastHandledSeq, existing) }
        observingCommands = true
        lock.unlock()
        if shouldRegister { DarwinBridge.addObserver(self, name: commandName) }
    }

    public func writeState(_ state: SessionState) {
        writeState(state, retryable: false)
    }

    /// `retryable` marks a `.failed` state whose audio was kept (see `readRetryable()`).
    public func writeState(_ state: SessionState, retryable: Bool) {
        var envelope = StateEnvelope(state: state, retryable: retryable)
        lock.lock()
        if lastPostedSignificant == nil, let onDisk = readEnvelope() {
            // First write of this process: keep the timestamp of an unchanged state.
            lastPostedSignificant = onDisk.significant
            lastChangedAt = onDisk.changedAt
        }
        let changed = lastPostedSignificant != envelope.significant
        envelope.changedAt = changed ? Date() : (lastChangedAt ?? Date())
        lock.unlock()
        do {
            try WireCoding.write(envelope, to: stateURL)
        } catch {
            return
        }
        lock.lock()
        lastPostedSignificant = envelope.significant
        lastChangedAt = envelope.changedAt
        lock.unlock()
        if changed { DarwinBridge.post(stateName) }
    }

    public func writeLevel(_ level: Float) {
        levelSlot.write(level)
    }

    // MARK: Internals (internal for tests)

    func send(_ command: SessionCommand, request: DictationRequest?, sentAt: Date, post: Bool) {
        lock.lock()
        var log = readCommandLog()
        let seq = Self.nextSequence(after: max(log.records.last?.seq ?? 0, lastSentSeq), now: sentAt)
        lastSentSeq = seq
        log.append(CommandRecord(seq: seq, command: command, request: request, sentAt: sentAt))
        try? WireCoding.write(log, to: commandsURL)
        lock.unlock()
        if post { DarwinBridge.post(commandName) }
    }

    /// Milliseconds since 1970, bumped past the previous value. Time-based so a deleted or
    /// reset command file cannot make a new command look older than one already handled.
    static func nextSequence(after previous: Int64, now: Date) -> Int64 {
        max(previous + 1, Int64(now.timeIntervalSince1970 * 1000))
    }

    func readCommandLog() -> CommandLog {
        WireCoding.read(CommandLog.self, from: commandsURL) ?? CommandLog()
    }

    func readEnvelope() -> StateEnvelope? {
        WireCoding.read(StateEnvelope.self, from: stateURL)
    }

    /// Darwin callbacks arrive on the main thread in practice; hop there if they don't.
    func didReceiveDarwinNotification(_ name: String) {
        if Thread.isMainThread {
            route(name)
        } else {
            DispatchQueue.main.async { self.route(name) }
        }
    }

    private func route(_ name: String) {
        if name == commandName { drainCommands() }
        if name == stateName { deliverState() }
    }

    /// Applies every command newer than the last handled one, oldest first.
    func drainCommands(now: Date = Date()) {
        let log = readCommandLog()
        lock.lock()
        let pending = log.records.filter { $0.seq > lastHandledSeq }.sorted { $0.seq < $1.seq }
        if let newest = pending.last { lastHandledSeq = newest.seq }
        let handlers = commandHandlers
        lock.unlock()

        for record in pending {
            if record.command == .start {
                guard record.request != nil,
                      now.timeIntervalSince(record.sentAt) <= Self.startCommandMaxAge else { continue }
            }
            handlers.forEach { $0(record.command, record.request) }
        }
    }

    private func deliverState() {
        guard let envelope = readEnvelope() else { return }
        lock.lock()
        let isNew = lastDeliveredSignificant != envelope.significant
        lastDeliveredSignificant = envelope.significant
        let handlers = stateHandlers
        lock.unlock()
        guard isNew else { return }
        handlers.forEach { $0(envelope.state) }
    }
}
