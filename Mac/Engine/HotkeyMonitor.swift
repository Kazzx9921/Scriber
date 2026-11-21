import AppKit
import ApplicationServices
import ScriberShared

/// The global hotkey, in two ways (see `HotkeySelection`):
/// - **Single key** through a `CGEventTap` (needs Accessibility): a lone modifier on either side
///   (right ⌥ by default), Fn/🌐, or a function key F1–F20 (`TriggerKey`).
/// - **Key combination** through Carbon `RegisterEventHotKey` (`ComboHotkeys`, no permission):
///   ⌥Space by default. Registered while Accessibility is missing, and kept until the tap is
///   actually running, so there is always a working hotkey. A combination another app or macOS
///   already uses is reported (`HotkeyRuntime`), never silently shared.
/// The owner sees the same `HotkeyEvent`s from both.
///
/// Event tap details:
/// - The tap lives on its own thread with its own run loop, so a busy main thread can never make
///   the system time the tap out (and never adds latency to the user's typing).
/// - It observes flags-changed, key down/up and mouse-down events. It never changes them and only
///   swallows Escape while a dictation is recording (see `HotkeyStateMachine`).
/// - Events Scriber posts itself (⌘V / ⌘C) carry `SyntheticKeys.marker` and are ignored.
/// - If macOS disables the tap (callback too slow, or "disabled by user input"), the callback
///   re-enables it immediately; `check()` (called every 2 s) re-enables it too, creates the tap
///   once Accessibility is granted, and removes it when the permission is revoked.
/// - Ordinary key codes are never logged; only hotkey decisions are.
final class HotkeyMonitor: @unchecked Sendable {
    enum Status: String, Sendable {
        case stopped
        case needsAccessibility
        case starting
        case running
        /// Accessibility is granted but the tap could not be created (a relaunch usually helps).
        case failed
    }

    /// Main thread.
    var onEvent: ((HotkeyEvent) -> Void)?

    /// Main thread only.
    private(set) var status: Status = .stopped
    /// How many times in a row tap creation failed while trusted.
    private(set) var consecutiveFailures = 0

    // Guarded by `lock` (touched by the tap thread, timers and the main thread).
    private let lock = NSLock()
    private var machine: HotkeyStateMachine
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var generation = 0

    /// Main thread only.
    private var thread: Thread?
    private var reenableCount = 0

    // Key combination path. Main thread only.
    private let combos = ComboHotkeys()
    private var config: HotkeyConfig
    private var comboRegistration: ComboRegistration = .off
    private var registeredBindings: [ComboBinding] = []
    private var lastComboAttempt: TimeInterval = -.infinity
    private var accessibilityTrusted = false
    private var paused = false
    private var recording = false
    /// A combination that is taken is tried again this often (the other app may have quit).
    private static let comboRetryInterval: TimeInterval = 10

    init(config: HotkeyConfig) {
        machine = HotkeyStateMachine(config: config)
        self.config = config
        combos.onPress = { [weak self] kind in self?.comboPressed(kind) }
        combos.onRelease = { [weak self] kind in self?.comboReleased(kind) }
    }

    // MARK: Owner API (main thread)

    func update(config: HotkeyConfig) {
        lock.lock()
        machine.config = config
        machine.reset()
        lock.unlock()
        let comboChanged = config.combo != self.config.combo
        self.config = config
        DiagLog.log("hotkey", "config \(config.logDescription)")
        reconcile(force: comboChanged)
    }

    func setRecording(_ recording: Bool) {
        lock.lock()
        machine.isRecording = recording
        lock.unlock()
        self.recording = recording
        reconcile()
    }

    /// While the settings screen captures a new trigger key.
    func setPaused(_ paused: Bool) {
        lock.lock()
        let changed = machine.isPaused != paused
        machine.isPaused = paused
        if changed { machine.reset() }
        lock.unlock()
        if changed { DiagLog.log("hotkey", paused ? "paused (choosing a key)" : "resumed") }
        self.paused = paused
        reconcile()
    }

    /// Creates, repairs or removes the tap to match the Accessibility permission. Cheap; call it
    /// periodically.
    func check() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            // 說話改字 joins (or leaves) the combinations with the permission.
            registeredBindings = []
        }
        defer { reconcile() }
        guard trusted else {
            if thread != nil { stopTap(reason: "accessibility not granted any more") }
            setStatus(.needsAccessibility)
            return
        }
        if thread == nil {
            startTap()
            return
        }
        lock.lock()
        let current = tap
        lock.unlock()
        if let current, !CGEvent.tapIsEnabled(tap: current) {
            CGEvent.tapEnable(tap: current, enable: true)
            reenableCount += 1
            DiagLog.log("hotkey", "watchdog: tap was disabled → re-enabled (#\(reenableCount))")
        }
    }

    func stop() {
        stopTap(reason: "app quitting")
        setStatus(.stopped)
        combos.unregisterAll()
        comboRegistration = .off
        registeredBindings = []
    }

    // MARK: Key combination (main thread)

    /// Registers or removes the combinations (and Esc) to match `HotkeySelection`, then publishes
    /// the hotkey that works.
    private func reconcile(force: Bool = false) {
        let plan = HotkeySelection.plan(accessibilityTrusted: accessibilityTrusted, tapRunning: status == .running,
                                        paused: paused)
        if plan.registerCombo {
            let bindings = HotkeySelection.comboBindings(for: config, includeEdit: accessibilityTrusted)
            let now = ProcessInfo.processInfo.systemUptime
            var retry = false
            if case .taken = comboRegistration { retry = now - lastComboAttempt >= Self.comboRetryInterval }
            if force || retry || comboRegistration == .off || bindings != registeredBindings {
                lastComboAttempt = now
                let result = combos.register(bindings)
                registeredBindings = bindings
                if result != comboRegistration || force {
                    DiagLog.log("hotkey", "combo \(config.combo.logDescription) → \(Self.describe(result)) "
                                + "variants=\(bindings.count - 1) ax=\(accessibilityTrusted)")
                }
                comboRegistration = result
            }
        } else if comboRegistration != .off {
            combos.unregisterBindings()
            registeredBindings = []
            comboRegistration = .off
            DiagLog.log("hotkey", paused ? "combo released while choosing a key" : "combo released: single key active")
        }
        combos.setEscape(HotkeySelection.wantsEscape(recording: recording, plan: plan, combo: comboRegistration))
        publish()
    }

    private func publish() {
        let state = HotkeyRuntimeState(
            active: HotkeySelection.active(config: config, accessibilityTrusted: accessibilityTrusted,
                                           tapRunning: status == .running, combo: comboRegistration, paused: paused),
            combo: comboRegistration,
            // Sticky across the retry loop (starting → failed every 2 s) until a tap runs.
            tapFailed: accessibilityTrusted && consecutiveFailures > 0 && status != .running)
        MainActor.assumeIsolated { HotkeyRuntime.shared.update(state) }
    }

    private func comboPressed(_ kind: ComboHotkeys.Kind) {
        switch kind {
        case .escape:
            emitCombo(.escape)
        case .binding(let binding):
            emitCombo(config.mode == .toggle ? .tap(binding.variant) : .holdBegan(binding.variant))
        }
    }

    private func comboReleased(_ kind: ComboHotkeys.Kind) {
        guard case .binding = kind, config.mode == .hold else { return }
        emitCombo(.holdEnded)
    }

    private func emitCombo(_ event: HotkeyEvent) {
        DiagLog.log("hotkey", "combo event \(Self.describe(event))")
        onEvent?(event)
    }

    private static func describe(_ registration: ComboRegistration) -> String {
        switch registration {
        case .off: "off"
        case .registered: "registered"
        case .taken(let conflict): "taken(\(conflict.rawValue))"
        }
    }

    // MARK: Tap lifecycle

    private func startTap() {
        setStatus(.starting)
        lock.lock()
        generation += 1
        let myGeneration = generation
        lock.unlock()
        let thread = Thread { [weak self] in
            self?.runTap(generation: myGeneration)
        }
        thread.name = "com.geekaz.Scriber.hotkey"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    private func stopTap(reason: String) {
        lock.lock()
        generation += 1
        let loop = runLoop
        let current = tap
        machine.reset()
        lock.unlock()
        if let current { CGEvent.tapEnable(tap: current, enable: false) }
        if let loop { CFRunLoopStop(loop) }
        thread = nil
        DiagLog.log("hotkey", "tap stopped: \(reason)")
    }

    /// Runs on the tap thread until `stopTap`.
    private func runTap(generation myGeneration: Int) {
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                             eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: refcon) else {
            DispatchQueue.main.async { [weak self] in self?.tapCreationFailed(generation: myGeneration) }
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            DispatchQueue.main.async { [weak self] in self?.tapCreationFailed(generation: myGeneration) }
            return
        }
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)

        lock.lock()
        let stillWanted = generation == myGeneration
        if stillWanted {
            tap = newTap
            runLoop = loop
            machine.reset()
        }
        lock.unlock()

        if stillWanted {
            CGEvent.tapEnable(tap: newTap, enable: true)
            DispatchQueue.main.async { [weak self] in self?.tapStarted(generation: myGeneration) }
            CFRunLoopRun() // until CFRunLoopStop from stopTap
        }

        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(newTap)
        lock.lock()
        if tap === newTap {
            tap = nil
            runLoop = nil
        }
        lock.unlock()
    }

    private func tapStarted(generation myGeneration: Int) {
        lock.lock()
        let current = generation == myGeneration
        let config = machine.config
        lock.unlock()
        guard current else { return }
        consecutiveFailures = 0
        setStatus(.running)
        DiagLog.log("hotkey", "tap running \(config.logDescription)")
        reconcile()
    }

    private func tapCreationFailed(generation myGeneration: Int) {
        lock.lock()
        let current = generation == myGeneration
        lock.unlock()
        guard current else { return }
        thread = nil
        consecutiveFailures += 1
        setStatus(.failed)
        // Retried by the next `check()`; log the first few and then every 30th (one a minute).
        if consecutiveFailures <= 3 || consecutiveFailures % 30 == 0 {
            DiagLog.log("hotkey", "tap creation failed (#\(consecutiveFailures)) trusted=\(AXIsProcessTrusted())")
        }
        reconcile()
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        let old = status
        status = new
        if new != .starting, !(old == .starting && new == .running) {
            DiagLog.log("hotkey", "status \(old.rawValue) → \(new.rawValue)")
        }
    }

    // MARK: Event handling (tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let current = tap
            machine.reset()
            lock.unlock()
            if let current { CGEvent.tapEnable(tap: current, enable: true) }
            DiagLog.log("hotkey", "tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "userInput") → re-enabled")
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticKeys.marker {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let input: HotkeyInput
        switch type {
        case .flagsChanged:
            input = .flagsChanged(keyCode: keyCode, flags: event.flags.rawValue)
        case .keyDown:
            input = .keyDown(keyCode: keyCode, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                             flags: event.flags.rawValue)
        case .keyUp:
            input = .keyUp(keyCode: keyCode)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            input = .mouseDown
        default:
            return Unmanaged.passUnretained(event)
        }
        let output = feed(input)
        return output.swallow ? nil : Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func feed(_ input: HotkeyInput) -> HotkeyStateMachine.Output {
        lock.lock()
        let output = machine.handle(input, at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        if let delay = output.tickAfter {
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.feed(.tick)
            }
        }
        if let event = output.event {
            DispatchQueue.main.async { [weak self] in
                DiagLog.log("hotkey", "event \(Self.describe(event))")
                self?.onEvent?(event)
            }
        }
        if let note = output.note {
            DiagLog.log("hotkey", note)
        }
        return output
    }

    private static func describe(_ event: HotkeyEvent) -> String {
        switch event {
        case .tap(let variant): "tap(\(variant.rawValue))"
        case .holdBegan(let variant): "holdBegan(\(variant.rawValue))"
        case .holdEnded: "holdEnded"
        case .holdAborted: "holdAborted"
        case .escape: "escape"
        }
    }
}

/// C callback for the tap; `refcon` is the unretained `HotkeyMonitor` (it lives as long as the app).
private let hotkeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
