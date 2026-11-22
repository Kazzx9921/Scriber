import AppKit
import Observation
import ScriberCore
import ScriberShared

/// Hotkey → recorder → pipeline → paste, and the state the menu and HUD show.
///
/// Phases: idle → recording → processing → idle. Every step is written to `DiagLog` (ids,
/// durations, levels, provider names, error types — never transcripts, inserted or selected text,
/// or keys).
///
/// Real-time transcription (docs/PRD-macOS版.md, 即時辨識): when it applies (setting on, engine
/// ElevenLabs Scribe, key present), a `RealtimeSTTSession` streams the clip's 16 kHz audio while the
/// clip is still recorded as usual; the HUD shows the recognized text. At stop the session's final
/// transcript goes through the normal post-processing (`DictationPipeline.run(transcript:…)`).
/// If the session failed, or its final commit does not arrive in time, the recorded clip takes the
/// batch path instead — exactly one of the two produces the inserted text.
///
/// 設定 → 音訊 (docs/PRD-macOS版.md): `RecordingAudioSession` wraps every recording — `begin` right
/// before the microphone starts (pause media, start cue, mute after the cue), `end` right after it
/// stops on every path (unmute, stop cue only for a normal stop, resume media after the delay).
/// The microphone itself follows the pinned device (`MacRecorder` / `InputEngine`).
///
/// Modes (docs/PRD-模式.md): the press picks the mode (`DictationStart.plan`: a mode's own hotkey >
/// the app in front (自動套用) > the current mode); the mode's 情境 (app name, clipboard, selection)
/// is read at the start only when the mode sends it to its AI; the result is pasted (then
/// optionally Return / ⌘Return), only copied, or shown in the answer panel (`ResultDelivery`).
@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()

    enum Phase: String {
        case idle, recording, processing
    }

    struct RecentResult: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var date: Date
        var mode: DictationMode
    }

    private(set) var phase: Phase = .idle
    private(set) var currentMode: DictationMode = .dictate
    /// The mode being recorded or processed (docs/PRD-模式.md): name and icon for the status line.
    private(set) var currentStart: DictationStart?
    /// Newest first, at most `recentLimit` (memory only).
    private(set) var recent: [RecentResult] = []
    /// The last problem, for the menu's status line; cleared by the next dictation.
    private(set) var lastProblem: HUDFeedback?
    /// The last failure kept its audio (network/server error); `retry()` re-runs it.
    private(set) var canRetry = false
    private(set) var hotkeyStatus: HotkeyMonitor.Status = .stopped
    private(set) var hotkeyFailures = 0
    private(set) var accessibilityTrusted = false
    private(set) var micPermission: MicPermission = .notDetermined
    private(set) var secureInputActive = false
    private(set) var secureInputOwnerName: String?
    /// Briefly true after a problem, for the menu bar icon.
    private(set) var errorFlash = false

    var lastText: String? { recent.first?.text }

    static let recentLimit = 5

    // MARK: Collaborators and private state

    private struct Capture {
        var request: DictationRequest
        var url: URL
        var startedAt: Date
        var via: String
        /// Started at hotkey time for 說話改字 (Accessibility read, no side effects).
        var selection: Task<SelectionReader.AXResult, Never>?
        /// Real-time session riding along, if real-time applies to this dictation.
        var live: LiveRun?
        var start: DictationStart?
    }

    private struct Job {
        let id = UUID()
        var request: DictationRequest
        var url: URL
        var seconds: Double
        var task: Task<Void, Never>?
        var live: LiveRun?
        var start: DictationStart?
    }

    /// One real-time session and the text it has shown.
    @MainActor
    private final class LiveRun {
        let session: RealtimeSTTSession
        let text: RealtimeLiveText
        var consumer: Task<Void, Never>?
        /// The session failed while recording: the batch path runs at stop.
        var failure: RealtimeSTTError?
        /// `session.finish()`, started the moment recording stops.
        var final: Task<String, Error>?

        init(session: RealtimeSTTSession, forceTraditional: Bool) {
            self.session = session
            text = RealtimeLiveText(forceTraditional: forceTraditional)
        }

        func cancel() {
            session.cancel()
            consumer?.cancel()
        }
    }

    /// How much committed text the HUD gets (it shows the last two lines; see `RealtimeLiveText.tail`).
    private static let liveCommittedCharacters = 120
    /// After this many real-time failures in a row, use the batch path for a while (a protocol
    /// change on the server must not add a commit timeout to every dictation).
    private static let realtimeFailureLimit = 3
    private static let realtimePause: TimeInterval = 600

    private struct Kept {
        var url: URL
        var request: DictationRequest
        var seconds: Double
        var start: DictationStart?
    }

    @ObservationIgnored private let settings = MacSettings.shared
    @ObservationIgnored private let hud = HUDController()
    @ObservationIgnored private let answers = AnswerPanelController()
    @ObservationIgnored private let recorder = MacRecorder()
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private let files = MacRecordingFiles()
    @ObservationIgnored private let monitor: HotkeyMonitor
    @ObservationIgnored private var capture: Capture?
    @ObservationIgnored private var job: Job?
    @ObservationIgnored private var kept: Kept?
    @ObservationIgnored private var housekeeping: Timer?
    @ObservationIgnored private var maxDurationWork: DispatchWorkItem?
    @ObservationIgnored private var errorFlashWork: DispatchWorkItem?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var realtimeFailures = 0
    @ObservationIgnored private var realtimePausedUntil: Date?
    @ObservationIgnored private let audio: RecordingAudioSession
    @ObservationIgnored private var micNotice = MicFallbackNotice()
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []
    @ObservationIgnored private var didShutdown = false

    private init() {
        monitor = HotkeyMonitor(config: MacSettings.shared.hotkey)
        let scheduler = MainQueueScheduler()
        audio = RecordingAudioSession(
            cues: SoundCues.shared,
            muter: OutputMuter(port: CoreAudioOutputPort(), defaults: AppGroup.defaults),
            media: MediaPauseCoordinator(port: MediaRemoteScript(), scheduler: scheduler),
            scheduler: scheduler,
            outputKind: { CoreAudioQuery.defaultOutputKind() })
    }

    // MARK: Lifecycle

    /// Called once at launch. Does not touch the microphone and does not prompt for anything.
    func start() {
        guard !started else { return }
        started = true
        // First of all: a previous run that ended while the output was muted gives the sound back.
        audio.muter.recoverAtLaunch()
        if let line = AudioPreferences.migrate(AppGroup.defaults) { DiagLog.log("app", "settings audio \(line)") }
        // Asked before the modes migration below marks this install as migrated.
        let existingInstall = AutoApplyMigration.isExistingInstall(
            onboardingDone: settings.hasCompletedOnboarding, modesMigrationVersion: ModeMigration.completedVersion(),
            hasAnyKey: !settings.storedKeys.isEmpty)
        // Modes (docs/PRD-模式.md, M1): once, record the 說話改字 / 翻譯 modifier keys on 改寫 / 翻譯.
        ModeMigration.runIfNeeded(legacy: LegacyModeSettings(macEditModifier: settings.hotkey.editModifier.rawValue,
                                                             macTranslateModifier: settings.hotkey.translateModifier.rawValue))
        // M3: 自動套用 starts working; an existing install does not suddenly get Email in Mail.
        AutoApplyMigration.runIfNeeded(store: .shared, defaults: AppGroup.defaults, existingInstall: existingInstall) {
            DiagLog.log("modes", $0)
        }
        SoundCues.shared.prepare()
        installTerminationSignals()
        FocusInfo.configureTimeout()
        let purged = files.purgeAll()
        accessibilityTrusted = Permissions.isAccessibilityTrusted
        micPermission = Permissions.microphone
        let inputs = CoreAudioQuery.inputDevices()
        let defaultInput = CoreAudioQuery.defaultInputDeviceID().flatMap { id in inputs.first { $0.id == id } }
        DiagLog.log("app", "launch app=\(MacDiag.appVersion) macOS=\(MacDiag.osVersion) machine=\(MacDiag.machine) "
                    + "ax=\(accessibilityTrusted) mic=\(micPermission.rawValue) hotkey[\(settings.hotkey.logDescription)] "
                    + "\(settings.logDescription) pasteboard=\(Permissions.pasteboardAccess) "
                    + "launchAtLogin=\(LaunchAtLogin.statusDescription) purgedClips=\(purged) "
                    + "audio[\(AudioPreferences.load(from: AppGroup.defaults).logDescription)] "
                    + "inputs=\(inputs.count) defaultInput=\(defaultInput?.logDescription ?? "-") "
                    + "output=\(CoreAudioQuery.defaultOutputKind().rawValue)")
        AudioDeviceMonitor.shared.start()
        observers.append(NotificationCenter.default.addObserver(forName: .scriberAudioDevicesChanged, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioDevicesChanged() }
        })

        monitor.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        recorder.onInputLost = { [weak self] reason in
            MainActor.assumeIsolated { self?.inputLost(reason: reason) }
        }
        // The first AAC encoder setup is slow; get it out of the way before the first clip.
        DispatchQueue.global(qos: .utility).async {
            let millis = ClipWriter.prewarmEncoder()
            DiagLog.log("rec", "encoder prewarm ms=\(millis)")
        }
        refreshEnvironment()
        // Modes (M2): from here on the modes' hotkeys (改寫 and 翻譯 included) decide what a modifier
        // held with the trigger, or a mode's own combination, starts.
        trackModes()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEnvironment() }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeeping = timer

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                DiagLog.log("engine", "system going to sleep while recording → cancel")
                self.cancel(reason: "sleep", silent: true)
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DiagLog.log("app", "woke from sleep")
                self?.refreshEnvironment()
            }
        })
    }

    func shutdown() {
        // A second copy quitting at launch never started; it must not touch the running one's files.
        guard started, !didShutdown else { return }
        didShutdown = true
        DiagLog.log("app", "quit phase=\(phase.rawValue)")
        if phase == .recording { recorder.discard() }
        answers.close()
        // Unmute and resume media (right away) on every quit, recording or not.
        audio.shutdown()
        MicLevelTest.running?.stop()
        capture?.live?.cancel()
        job?.live?.cancel()
        job?.task?.cancel()
        monitor.stop()
        inserter.flushPendingRestore()
        housekeeping?.invalidate()
        files.purgeAll()
    }

    /// Permissions, secure input and the event tap. Every 2 s and on demand (cheap, no prompts).
    func refreshEnvironment() {
        let trusted = Permissions.isAccessibilityTrusted
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            DiagLog.log("app", "accessibility trusted=\(trusted)")
        }
        let mic = Permissions.microphone
        if mic != micPermission {
            micPermission = mic
            DiagLog.log("app", "microphone permission=\(mic.rawValue)")
        }
        let secure = Permissions.secureInputActive
        if secure != secureInputActive {
            secureInputActive = secure
            let owner = secure ? Permissions.secureInputOwner() : nil
            secureInputOwnerName = owner?.localizedName
            DiagLog.log("app", "secure input \(secure ? "on owner=\(MacDiag.app(owner))" : "off")")
        }
        monitor.check()
        if hotkeyStatus != monitor.status { hotkeyStatus = monitor.status }
        if hotkeyFailures != monitor.consecutiveFailures { hotkeyFailures = monitor.consecutiveFailures }
    }

    func applyHotkey(_ config: HotkeyConfig) {
        monitor.update(config: config)
    }

    // MARK: Modes

    /// Hands the modes' hotkeys to the monitor now and whenever the modes or the prompt library
    /// change (a prompt's kind decides whether a mode reads the selection).
    private func trackModes() {
        let (modes, prompts) = withObservationTracking {
            (ModeStore.shared.modes, PromptLibrary.shared.prompts)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.trackModes() }
        }
        monitor.update(modeHotkeys: ModeHotkeyCandidate.list(modes: modes, prompts: prompts))
        // Keep the saved hotkey settings describing 改寫 / 翻譯 (an older build reads only those).
        let legacy = HotkeyRoutes.legacyModifiers(in: modes)
        if settings.hotkey.editModifier != legacy.edit || settings.hotkey.translateModifier != legacy.translate {
            settings.hotkey.editModifier = legacy.edit
            settings.hotkey.translateModifier = legacy.translate
        }
        // The menu's 翻譯 lock means "翻譯 is the current mode"; it cannot outlive the mode.
        if settings.translateLocked, modes.first(where: { $0.id == BuiltInModeID.translate.rawValue })?.isEnabled == false {
            settings.translateLocked = false
        }
    }

    /// While the settings screen listens for a new trigger key.
    func pauseHotkey(_ paused: Bool) {
        monitor.setPaused(paused)
    }

    // MARK: Hotkey

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .tap(let variant):
            switch phase {
            case .idle: begin(variant, via: "tap")
            case .recording: finish(via: "tap")
            case .processing: DiagLog.log("engine", "tap ignored while processing")
            }
        case .holdBegan(let variant):
            if phase == .idle {
                begin(variant, via: "hold")
            } else {
                DiagLog.log("engine", "hold ignored while \(phase.rawValue)")
            }
        case .holdEnded:
            if phase == .recording { finish(via: "release") }
        case .holdAborted:
            if phase == .recording { cancel(reason: "combination", silent: true) }
        case .escape:
            guard phase == .recording else { break }
            // Esc must be pressed twice to cancel: a single Esc is too easy to hit by habit
            // (closing a popup, a terminal app) and would throw away what was being said.
            let now = Date()
            if let last = lastEscapeAt, now.timeIntervalSince(last) <= Self.escapeConfirmWindow {
                lastEscapeAt = nil
                cancel(reason: "escape", silent: false)
            } else {
                lastEscapeAt = now
                hud.flashRecordingHint("再按一次 esc 取消", for: Self.escapeConfirmWindow)
                DiagLog.log("engine", "escape once: waiting for a second press")
            }
        }
    }

    /// A second Esc within this many seconds of the first cancels the recording.
    static let escapeConfirmWindow: TimeInterval = 1.5
    private var lastEscapeAt: Date?

    // MARK: Menu actions

    /// 開始聽寫 / 結束 / 取消 from the menu.
    func toggleFromMenu() {
        switch phase {
        case .idle: begin(.dictate, via: "menu")
        case .recording: finish(via: "menu")
        case .processing: cancel(reason: "menu", silent: false)
        }
    }

    func cancelFromMenu() {
        cancel(reason: "menu", silent: false)
    }

    func copyLast() {
        guard let text = lastText else { return }
        copy(text)
    }

    func copy(_ text: String) {
        inserter.copyForManualPaste(text)
        DiagLog.log("app", "copied a result from the menu chars=\(text.count)")
    }

    // MARK: Recording

    private func begin(_ variant: HotkeyVariant, via: String) {
        guard phase == .idle else { return }
        let defaults = ModeDefaults(settings: AppSettings.shared)
        // The app in front picks the mode for the main hotkey (自動套用); Scriber's own window never does.
        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier.flatMap { $0 == Bundle.main.bundleIdentifier ? nil : $0 }
        settings.refreshKeys()
        let readiness = ModeReadiness(hasLLMKey: settings.hasLLMKey,
                                      readyEngines: Set(STTProviderKind.allCases.filter { settings.isReady($0) }))
        guard let start = DictationStart.plan(variant, translateLocked: settings.translateLocked,
                                              modes: ModeStore.shared.snapshot(), prompts: PromptLibrary.shared.snapshot(),
                                              defaults: defaults, frontmostBundleID: variant == .dictate ? frontID : nil,
                                              readiness: readiness) else {
            DiagLog.log("engine", "start via=\(via) ignored: \(variant.logName) is not a mode any more")
            return
        }
        if !start.autoApplySkipped.isEmpty || start.autoAppliedFor != nil {
            DiagLog.log("engine", "auto-apply front=\(frontID ?? "-") mode=\(start.modeID) "
                        + "applied=\(start.autoAppliedFor != nil) skipped=\(start.autoApplySkipped.joined(separator: ","))")
        }
        let mode = start.legacyMode

        micPermission = Permissions.microphone
        switch micPermission {
        case .granted:
            break
        case .notDetermined:
            DiagLog.log("engine", "start via=\(via): asking for microphone permission")
            Task { [weak self] in
                let granted = await Permissions.requestMicrophone()
                guard let self else { return }
                self.micPermission = Permissions.microphone
                DiagLog.log("engine", "microphone permission answered granted=\(granted)")
                if granted {
                    self.show(.micGranted)
                } else {
                    self.show(.needsMicrophone())
                }
            }
            return
        case .denied, .restricted:
            DiagLog.log("engine", "start via=\(via) refused: microphone \(micPermission.rawValue)")
            show(.needsMicrophone())
            return
        }

        let engine = start.resolved.sttProvider
        guard settings.isReady(engine) else {
            DiagLog.log("engine", "start via=\(via) refused: engine \(engine.rawValue) not ready mode=\(start.modeID)")
            show(.needsSpeechKey())
            return
        }
        if start.requiresLLM, !settings.hasLLMKey {
            DiagLog.log("engine", "start via=\(via) refused: \(mode.rawValue) mode=\(start.modeID) needs an LLM key")
            switch start.requestModeID == nil ? mode : .dictate {
            case .edit: show(.needsLLMKey(for: .edit))
            case .translate: show(.needsLLMKey(for: .translate))
            case .dictate: show(.needsLLMKey(modeName: start.name))
            }
            return
        }

        dropKept(reason: "newDictation")
        lastProblem = nil
        MicLevelTest.running?.stop()
        var request = start.request()
        let tag = MacDiag.id(request.id)
        let startedAt = Date()
        // Connect first: the socket handshake (~0.3 s) overlaps the microphone start.
        let live = makeLiveRun(for: request, resolved: start.resolved)
        // Pause media, start cue, (deferred) mute — then the microphone, with no added delay.
        let audioPrefs = AudioPreferences.load(from: AppGroup.defaults)
        let plan = audio.begin(audioPrefs, tag: tag)
        let url: URL
        do {
            var sink: (@Sendable ([Float]) -> Void)?
            if let session = live?.session {
                sink = { samples in session.append(samples: samples) }
            }
            url = try recorder.start(baseURL: files.newClipBaseURL(), pinnedUID: audioPrefs.inputDeviceUID,
                                     silenceGate: plan.silenceGate, logTag: tag, streamSink: sink)
        } catch {
            audio.end(.failed)
            live?.cancel()
            let message: String
            switch error as? MacRecorder.Failure {
            case .noInputDevice?: message = "找不到麥克風，請確認輸入裝置"
            default: message = "無法開始錄音，請再試一次"
            }
            DiagLog.log("engine", "start id=\(MacDiag.id(request.id)) via=\(via) recorder failed \(Self.describe(error))")
            show(HUDFeedback.forFailure(message: message, retryable: false))
            return
        }

        var selection: Task<SelectionReader.AXResult, Never>?
        if start.needsSelection {
            selection = Task.detached(priority: .userInitiated) { SelectionReader.readViaAccessibility() }
        }
        // 情境 the mode sends to its AI, read now that the microphone runs (a pasteboard prompt from
        // macOS cannot cost any speech). Nothing is read for a mode that does not ask.
        if start.wantsAppName || start.wantsClipboard {
            var context = DictationStart.Context()
            var parts: [String] = []
            if start.wantsAppName {
                context.appName = front?.localizedName
                parts.append("app=\(context.appName?.count ?? 0)")
            }
            if start.wantsClipboard {
                let clip = ClipboardContext.read(SystemClipboard(), canRead: Permissions.canReadPasteboard)
                context.clipboard = clip.text
                parts.append("clipboard[\(clip.logDescription)]")
            }
            request = start.request(id: request.id, context: context)
            DiagLog.log("engine", "context id=\(tag) \(parts.joined(separator: " "))")
        }
        capture = Capture(request: request, url: url, startedAt: startedAt, via: via, selection: selection, live: live,
                          start: start)
        currentMode = mode
        currentStart = start
        phase = .recording
        monitor.setRecording(true)
        let badge = start.badge
        let recorder = self.recorder
        lastEscapeAt = nil
        hud.showRecording(mode: mode, badge: badge, symbol: start.showsMark ? start.icon : nil, live: live != nil) {
            recorder.level
        }
        if micNotice.shouldNotify(pinnedUID: audioPrefs.inputDeviceUID, route: recorder.route) {
            hud.flashRecordingHint(MicFallbackNotice.hudLabel, for: 2.4)
            DiagLog.log("engine", "id=\(tag) pinned microphone not used (\(recorder.route.logDescription)) → told the user")
        }

        maxDurationWork?.cancel()
        let requestID = request.id
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording, self.capture?.request.id == requestID else { return }
                DiagLog.log("engine", "max duration reached id=\(MacDiag.id(requestID))")
                self.finish(via: "maxDuration")
            }
        }
        maxDurationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipPolicy.maximumRecordingSeconds, execute: work)

        DiagLog.log("engine", "recording id=\(MacDiag.id(request.id)) via=\(via) mode=\(mode.rawValue) modeID=\(start.modeID) "
                    + "front=\(MacDiag.app(front)) input=\(recorder.inputDescription) route=\(recorder.route.logDescription) "
                    + "realtime=\(live != nil) startMs=\(MacDiag.millis(since: startedAt))")
    }

    // MARK: Real-time

    /// A started session if real-time applies to this dictation, else nil (logged when the
    /// setting is on but something else is missing).
    private func makeLiveRun(for request: DictationRequest, resolved: ResolvedModeConfig) -> LiveRun? {
        guard resolved.realtimeEnabled else { return nil }
        let tag = MacDiag.id(request.id)
        if let until = realtimePausedUntil, until > Date() {
            DiagLog.log("engine", "id=\(tag) realtime paused after \(realtimeFailures) failures in a row → batch "
                        + "(\(Int(until.timeIntervalSinceNow))s left)")
            return nil
        }
        let session: RealtimeSTTSession
        switch RealtimeSTTSession.make(resolved: resolved, logTag: tag) {
        case .failure(let reason):
            DiagLog.log("engine", "id=\(tag) realtime unavailable reason=\(reason.rawValue) → batch")
            return nil
        case .success(let made):
            session = made
        }
        let run = LiveRun(session: session, forceTraditional: resolved.forceTraditional)
        // The live text converts every partial; load the dictionaries before the first one arrives.
        Task.detached(priority: .utility) { ZhTW.prewarm() }
        session.start()
        let requestID = request.id
        run.consumer = Task { @MainActor [weak self, weak run] in
            for await event in session.events {
                guard let self, let run else { return }
                self.handleLive(event, run: run, requestID: requestID)
            }
        }
        return run
    }

    private func handleLive(_ event: RealtimeSTTEvent, run: LiveRun, requestID: String) {
        guard phase == .recording, let capture, capture.request.id == requestID, capture.live === run else { return }
        switch event {
        case .partial, .committed:
            guard run.failure == nil, run.text.apply(event) else { return }
            let tail = run.text.tail(maxCommittedCharacters: Self.liveCommittedCharacters)
            hud.updateLiveText(committed: tail.committed, partial: tail.partial)
        case .error(let error):
            run.failure = error
            DiagLog.log("engine", "id=\(MacDiag.id(requestID)) realtime failed while recording \(error.logDescription) "
                        + "→ batch at stop")
            hud.endLiveText()
        case .started, .closed:
            break
        }
    }

    /// The real-time transcript for a stopped recording, or nil when the batch path must run
    /// (logged with the reason). Throws only for cancellation.
    private func realtimeTranscript(_ run: LiveRun?, requestID: String, stoppedAt: Date) async throws -> (text: String, millis: Int)? {
        guard let run else { return nil }
        let tag = MacDiag.id(requestID)
        if let failure = run.failure {
            noteRealtime(success: false)
            DiagLog.log("pipe", "id=\(tag) path=batch reason=failed-while-recording \(failure.logDescription)")
            return nil
        }
        guard let final = run.final else { return nil }
        do {
            let text = try await final.value
            let millis = MacDiag.millis(since: stoppedAt)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                noteRealtime(success: false)
                DiagLog.log("pipe", "id=\(tag) path=batch reason=empty-realtime-transcript stopToFinalMs=\(millis)")
                return nil
            }
            noteRealtime(success: true)
            DiagLog.log("pipe", "id=\(tag) path=realtime stopToFinalMs=\(millis) chars=\(text.count)")
            return (text, millis)
        } catch {
            let realtimeError = error as? RealtimeSTTError
            if Task.isCancelled || realtimeError?.reason == .cancelled { throw ProviderError.cancelled }
            noteRealtime(success: false)
            DiagLog.log("pipe", "id=\(tag) path=batch reason=\(realtimeError?.logDescription ?? MacDiag.errorType(error)) "
                        + "afterMs=\(MacDiag.millis(since: stoppedAt))")
            return nil
        }
    }

    private func noteRealtime(success: Bool) {
        if success {
            realtimeFailures = 0
            realtimePausedUntil = nil
            return
        }
        realtimeFailures += 1
        if realtimeFailures >= Self.realtimeFailureLimit {
            realtimePausedUntil = Date().addingTimeInterval(Self.realtimePause)
            DiagLog.log("engine", "realtime failed \(realtimeFailures)× in a row → batch only for \(Int(Self.realtimePause))s")
        }
    }

    private func finish(via: String) {
        guard phase == .recording, let capture else { return }
        self.capture = nil
        maxDurationWork?.cancel()
        monitor.setRecording(false)
        // Stopping flushes the resampler tail into the real-time stream too.
        let summary = recorder.stop()
        // After the microphone has stopped: unmute, then the stop cue (never part of the recording),
        // then media resumes after its delay. Nothing below waits for any of it.
        audio.end(.finished)
        let stoppedAt = Date()
        let request = capture.request
        guard let summary else {
            DiagLog.log("engine", "capture end id=\(MacDiag.id(request.id)) via=\(via) produced no audio")
            phase = .idle
            capture.selection?.cancel()
            capture.live?.cancel()
            show(.forFailure(message: via == "inputLost" ? "麥克風中斷了" : "錄音失敗，請再試一次", retryable: false))
            return
        }
        // The start cue heard through speakers does not count as speech (see `RecordingAudioSession`).
        let peakAfterCue = recorder.peakAfterGate
        let verdict = ClipPolicy.verdict(duration: summary.duration, peakLevel: peakAfterCue ?? summary.peakLevel)
        DiagLog.log("engine", "capture end id=\(MacDiag.id(request.id)) via=\(via) dur=\(MacDiag.seconds(summary.duration))s "
                    + "peak=\(String(format: "%.2f", summary.peakLevel)) "
                    + "peakAfterCue=\(peakAfterCue.map { String(format: "%.2f", $0) } ?? "-") rateChanges=\(summary.rateChanges) "
                    + "format=\(summary.format.rawValue) kb=\(summary.fileBytes / 1024) verdict=\(verdict.rawValue)")
        switch verdict {
        case .keep:
            break
        case .tooShort, .silent:
            files.delete(summary.url)
            phase = .idle
            capture.selection?.cancel()
            capture.live?.cancel()
            let message: String
            if via == "inputLost" {
                message = "麥克風中斷了"
            } else {
                message = verdict == .tooShort ? "說話時間太短" : "沒有聽到聲音"
            }
            show(.forFailure(message: message, retryable: false))
            return
        }
        phase = .processing
        hud.showProcessing(mode: request.mode, symbol: Self.processingSymbol(capture.start))
        if let live = capture.live {
            live.consumer?.cancel()
            // Commit right away; 說話改字 may still be reading the selection meanwhile.
            if live.failure == nil {
                let session = live.session
                live.final = Task { try await session.finish() }
            }
        }
        process(url: summary.url, request: request, seconds: summary.duration, selection: capture.selection,
                selectionPending: capture.start?.needsSelection ?? (request.mode == .edit),
                selectionRequired: capture.start?.selectionRequired ?? (request.mode == .edit), live: capture.live,
                stoppedAt: stoppedAt, start: capture.start)
    }

    /// The HUD's processing pill shows the mode's icon (nothing for plain 聽寫).
    private static func processingSymbol(_ start: DictationStart?) -> String? {
        guard let start else { return nil }
        return start.showsMark ? start.icon : nil
    }

    private func cancel(reason: String, silent: Bool) {
        switch phase {
        case .recording:
            let id = capture?.request.id
            capture?.selection?.cancel()
            capture?.live?.cancel()
            capture = nil
            maxDurationWork?.cancel()
            monitor.setRecording(false)
            recorder.discard()
            // Silent: no stop cue. Sleep: media is not resumed after waking.
            audio.end(reason == "sleep" ? .sleep : .cancelled)
            phase = .idle
            DiagLog.log("engine", "recording cancelled id=\(MacDiag.id(id)) reason=\(reason)")
        case .processing:
            guard let job else { phase = .idle; return }
            self.job = nil
            job.live?.cancel()
            job.task?.cancel()
            files.delete(job.url)
            phase = .idle
            DiagLog.log("engine", "processing cancelled id=\(MacDiag.id(job.request.id)) reason=\(reason)")
        case .idle:
            return
        }
        if silent {
            hud.hide()
        } else {
            show(.cancelled)
        }
    }

    private func inputLost(reason: String) {
        guard phase == .recording else { return }
        DiagLog.log("engine", "input lost reason=\(reason) recorded=\(MacDiag.seconds(recorder.recordedSeconds))s → finishing")
        finish(via: "inputLost")
    }

    // MARK: Audio housekeeping

    /// A device came back: an unmute that could not happen earlier (device was away) gets done.
    private func audioDevicesChanged() {
        guard !audio.isActive, !audio.muter.pendingRecords.isEmpty else { return }
        audio.muter.restorePending(reason: "device-change")
    }

    /// `kill`, Ctrl-C in a terminal: quit through the normal path so the output is unmuted and paused
    /// media resumed. (A crash or `kill -9` is covered by `OutputMuter.recoverAtLaunch`.)
    private func installTerminationSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    DiagLog.log("app", "signal \(sig) → quitting")
                    self?.shutdown()
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Pipeline

    /// `selectionPending`: the selected text still has to be found (Accessibility result from the
    /// start). `selectionRequired`: it is what the mode works on (說話改字 / 改寫): the ⌘C fallback
    /// may be used, and without a selection the default mode runs. Otherwise it is only context.
    private func process(url: URL, request: DictationRequest, seconds: Double,
                         selection: Task<SelectionReader.AXResult, Never>?, selectionPending: Bool,
                         selectionRequired: Bool = true,
                         live: LiveRun? = nil, stoppedAt: Date = Date(), start: DictationStart? = nil) {
        var job = Job(request: request, url: url, seconds: seconds, live: live, start: start)
        let jobID = job.id
        let started = Date()
        job.task = Task { [weak self] in
            var request = request
            if selectionPending {
                let text = await self?.resolveSelection(selection, requestID: request.id, allowCopy: selectionRequired)
                if let text {
                    // Context is capped like the clipboard; the text a rewrite works on is not.
                    request.selectedText = selectionRequired || text.count <= ModeContextLimit.characters
                        ? text : String(text.prefix(ModeContextLimit.characters))
                } else if selectionRequired {
                    // Nothing selected: plain dictation (what the pipeline would do anyway).
                    request.mode = .dictate
                    request.selectedText = nil
                }
            }
            guard let self else { return }
            guard !Task.isCancelled, self.job?.id == jobID else { return }
            self.job?.request = request
            let settings = self.settings
            DiagLog.log("pipe", "start id=\(MacDiag.id(request.id)) mode=\(request.mode.rawValue) modeID=\(request.modeID ?? "-") "
                        + "stt=\(settings.sttProvider.rawValue) polish=\(settings.polishProvider.rawValue) "
                        + "realtime=\(live != nil) selectionChars=\(request.selectedText?.count ?? 0)")
            do {
                let pipeline = DictationPipeline()
                let result: PipelineResult
                // Exactly one path produces the text: the real-time transcript, or — only if there
                // is none — the recorded clip.
                if let streamed = try await self.realtimeTranscript(live, requestID: request.id, stoppedAt: stoppedAt) {
                    guard !Task.isCancelled, self.job?.id == jobID else { return }
                    result = try await pipeline.run(transcript: streamed.text, request: request, sttMillis: streamed.millis)
                } else {
                    guard !Task.isCancelled, self.job?.id == jobID else { return }
                    result = try await pipeline.run(audioFile: url, request: request)
                }
                await self.pipelineSucceeded(result, jobID: jobID, request: request, started: started)
            } catch {
                self.pipelineFailed(error, jobID: jobID, request: request, started: started)
            }
        }
        self.job = job
    }

    /// `allowCopy`: may post ⌘C when Accessibility cannot read the selection (only for what a
    /// rewrite works on; context never posts keys into the app).
    private func resolveSelection(_ axTask: Task<SelectionReader.AXResult, Never>?, requestID: String,
                                  allowCopy: Bool = true) async -> String? {
        let ax: SelectionReader.AXResult
        if let axTask {
            ax = await axTask.value
        } else {
            ax = await Task.detached(priority: .userInitiated) { SelectionReader.readViaAccessibility() }.value
        }
        let tag = MacDiag.id(requestID)
        switch ax {
        case .text(let text):
            DiagLog.log("edit", "id=\(tag) selection via=accessibility chars=\(text.count)")
            return text
        case .empty:
            DiagLog.log("edit", "id=\(tag) nothing selected (accessibility) → dictate")
            return nil
        case .unavailable(let reason) where !allowCopy:
            DiagLog.log("edit", "id=\(tag) selection context unavailable (\(reason)) → none")
            return nil
        case .unavailable(let reason):
            let copied = await SelectionReader.readViaCopy()
            DiagLog.log("edit", "id=\(tag) accessibility unavailable (\(reason)) → ⌘C fallback \(copied.detail) "
                        + "chars=\(copied.text?.count ?? 0)")
            return copied.text
        }
    }

    private func pipelineSucceeded(_ result: PipelineResult, jobID: UUID, request: DictationRequest, started: Date) async {
        guard let job, job.id == jobID else {
            DiagLog.log("pipe", "done id=\(MacDiag.id(request.id)) dropped (cancelled)")
            return
        }
        self.job = nil
        files.delete(job.url)
        let text = result.finalText
        DiagLog.log("pipe", "done id=\(MacDiag.id(request.id)) stt=\(result.sttProvider.rawValue) "
                    + "realtime=\(result.usedRealtime) "
                    + "polish=\(result.polishProvider.rawValue) sttMs=\(result.sttMillis) polishMs=\(result.polishMillis) "
                    + "totalMs=\(MacDiag.millis(since: started)) outChars=\(text.count)")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .idle
            show(.forFailure(message: ProviderError.emptyResult.errorDescription ?? "沒有辨識到內容", retryable: false))
            return
        }
        UsageStats.record(text: text, speakingSeconds: job.seconds)
        if settings.saveHistory {
            HistoryStore.shared.add(HistoryItem(
                mode: request.mode, rawTranscript: result.rawTranscript, finalText: text,
                sttProvider: result.sttProvider, polishProvider: result.polishProvider,
                totalMillis: MacDiag.millis(since: started)))
        }
        recent.insert(RecentResult(text: text, date: Date(), mode: request.mode), at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }

        let tag = MacDiag.id(request.id)
        let delivery = ResultDelivery(output: result.output, autoSend: result.autoSend)
        switch delivery {
        case .answer:
            // Not typed anywhere: the panel shows it (never takes focus).
            phase = .idle
            hud.hide()
            let ran = ModeStore.shared.mode(id: result.modeID)
            answers.show(answer: text, question: result.rawTranscript, title: ran?.name ?? job.start?.name ?? "回答",
                         symbol: ran?.icon ?? job.start?.icon ?? "bubble.left.and.text.bubble.right") { [weak self] answer in
                self?.inserter.copyForManualPaste(answer)
                DiagLog.log("engine", "answer copied chars=\(answer.count)")
            }
            DiagLog.log("engine", "finished id=\(tag) output=answer chars=\(text.count) totalMs=\(MacDiag.millis(since: started))")
        case .copyOnly:
            inserter.copyForManualPaste(text)
            phase = .idle
            show(.copiedOnly)
            DiagLog.log("engine", "finished id=\(tag) output=copyOnly totalMs=\(MacDiag.millis(since: started))")
        case .paste:
            let pasteTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let outcome = await inserter.insert(text, requestID: request.id, restoreClipboard: settings.restoreClipboard)
            switch outcome {
            case .pasted:
                hud.hide()
                await autoSend(delivery, pastedInto: pasteTarget, tag: tag)
                DiagLog.log("engine", "finished id=\(tag) output=\(delivery.logName) totalMs=\(MacDiag.millis(since: started))")
            case .copied(let feedback):
                if delivery != .paste(autoSend: .none) {
                    DiagLog.log("engine", "id=\(tag) auto-send skipped: not pasted")
                }
                show(feedback)
            }
            phase = .idle
        }
    }

    /// Return / ⌘Return after a paste that happened (docs/PRD-模式.md §7.5), into the same app only.
    private func autoSend(_ delivery: ResultDelivery, pastedInto pid: pid_t?, tag: String) async {
        guard case .paste(let autoSend) = delivery, autoSend != .none else { return }
        try? await Task.sleep(nanoseconds: UInt64(AutoSendGate.delay * 1_000_000_000))
        let front = NSWorkspace.shared.frontmostApplication
        let sameApp = pid != nil && front?.processIdentifier == pid
        guard let key = AutoSendGate.key(for: delivery, paste: .pasted, sameAppInFront: sameApp,
                                         secureInput: Permissions.secureInputActive) else {
            DiagLog.log("paste", "id=\(tag) auto-send skipped sameApp=\(sameApp) secure=\(Permissions.secureInputActive)")
            return
        }
        _ = await SyntheticKeys.waitForModifiersReleased()
        let posted = SyntheticKeys.postKey(keyCode: key.keyCode, command: key.command)
        DiagLog.log("paste", "id=\(tag) auto-send \(key.logName) posted=\(posted) front=\(MacDiag.app(front))")
    }

    private func pipelineFailed(_ error: Error, jobID: UUID, request: DictationRequest, started: Date) {
        guard let job, job.id == jobID else {
            DiagLog.log("pipe", "failed id=\(MacDiag.id(request.id)) after cancel (ignored) type=\(MacDiag.errorType(error))")
            return
        }
        self.job = nil
        phase = .idle
        if Self.isCancellation(error) {
            files.delete(job.url)
            hud.hide()
            DiagLog.log("pipe", "cancelled id=\(MacDiag.id(request.id)) ms=\(MacDiag.millis(since: started))")
            return
        }
        let retryable = Self.isRetryable(error)
        if retryable {
            kept = Kept(url: job.url, request: request, seconds: job.seconds, start: job.start)
        } else {
            files.delete(job.url)
        }
        canRetry = retryable
        DiagLog.log("pipe", "failed id=\(MacDiag.id(request.id)) type=\(MacDiag.errorType(error)) retryable=\(retryable) "
                    + "ms=\(MacDiag.millis(since: started))")
        show(.forFailure(message: Self.message(for: error), retryable: retryable))
    }

    /// Re-runs the last clip that failed on the network or server side.
    func retry() {
        guard phase == .idle, let kept else { return }
        self.kept = nil
        canRetry = false
        lastProblem = nil
        phase = .processing
        currentMode = kept.request.mode
        currentStart = kept.start
        hud.showProcessing(mode: kept.request.mode, symbol: Self.processingSymbol(kept.start))
        DiagLog.log("engine", "retry id=\(MacDiag.id(kept.request.id))")
        process(url: kept.url, request: kept.request, seconds: kept.seconds, selection: nil, selectionPending: false,
                start: kept.start)
    }

    private func dropKept(reason: String) {
        guard let kept else { return }
        files.delete(kept.url)
        self.kept = nil
        canRetry = false
        DiagLog.log("engine", "kept audio dropped id=\(MacDiag.id(kept.request.id)) reason=\(reason)")
    }

    // MARK: Feedback

    private func show(_ feedback: HUDFeedback) {
        DiagLog.log("engine", "feedback type=\(feedback.type) kind=\(feedback.kind.rawValue)")
        if feedback.isProblem {
            lastProblem = feedback
            errorFlash = true
            errorFlashWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.errorFlash = false }
            }
            errorFlashWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
        let action: (() -> Void)?
        switch feedback.kind {
        case .retry:
            action = { [weak self] in self?.retry() }
        case .needsSetup:
            // Keys and engines are fixed in 設定; permissions are listed on 首頁 (還差一步).
            let keyTypes: Set<String> = ["invalid-key", "missing-key", "needs-llm-key", "custom-engine"]
            let section: MainSection = keyTypes.contains(feedback.type) ? .settings : .home
            action = { WindowManager.shared.showMain(section) }
        default:
            action = nil
        }
        hud.showFeedback(feedback, onClick: action)
    }

    // MARK: Menu bar presentation

    var menuBarSymbol: String {
        switch phase {
        case .recording: return "mic.fill"
        case .processing: return "ellipsis.circle"
        case .idle:
            if needsAttention { return "mic.slash" }
            if errorFlash { return "exclamationmark.circle" }
            return "mic"
        }
    }

    /// Something stops the hotkey or the microphone from working at all.
    var needsAttention: Bool {
        !accessibilityTrusted || hotkeyStatus == .failed || micPermission == .denied || micPermission == .restricted
    }

    var statusLine: String {
        switch phase {
        case .recording:
            if let start = currentStart, start.requestModeID != nil {
                return "聆聽中…（\(start.name)）"
            }
            switch currentMode {
            case .dictate:
                guard let start = currentStart, start.showsMark else { return "聆聽中…" }
                return "聆聽中…（\(start.name)）"
            case .translate:
                let target = currentStart.flatMap { start in
                    TranslateLanguage.all.first { $0.promptName == start.resolved.translateTarget }
                } ?? settings.translateLanguage
                return "聆聽中…（翻譯成\(target.displayName)）"
            case .edit: return "聆聽中…（說話改字）"
            }
        case .processing:
            return "整理中…"
        case .idle:
            if !accessibilityTrusted { return "需要輔助使用權限，快捷鍵才能用" }
            if hotkeyStatus == .failed { return "快捷鍵沒有啟動，請重新開啟 Scriber" }
            if micPermission == .denied || micPermission == .restricted { return "需要麥克風權限" }
            if secureInputActive {
                let who = secureInputOwnerName.map { "「\($0)」" } ?? "某個 App"
                return "\(who)正在使用安全輸入，快捷鍵暫停"
            }
            if let lastProblem { return lastProblem.message }
            let key = settings.hotkey.trigger.shortName
            return settings.hotkey.mode == .toggle ? "按一下 \(key) 開始說話" : "按住 \(key) 說話"
        }
    }

    // MARK: Errors

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case ProviderError.cancelled = error { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return false
    }

    /// Network and server-side failures keep the audio for retry; anything the user must fix does not.
    static func isRetryable(_ error: Error) -> Bool {
        if let provider = error as? ProviderError {
            switch provider {
            case .network(let code): return code != "audio-file-unreadable"
            case .http(let status, _): return status == 408 || status == 429 || status >= 500
            default: return false
            }
        }
        if error is URLError { return true }
        return (error as NSError).domain == NSURLErrorDomain
    }

    static func message(for error: Error) -> String {
        if error is URLError || (error as NSError).domain == NSURLErrorDomain { return "網路連線失敗，請稍後再試" }
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty { return text }
        return "處理失敗，請再試一次"
    }

    private static func describe(_ error: Error) -> String {
        switch error as? MacRecorder.Failure {
        case .noInputDevice?: return "noInputDevice"
        case .engine(let underlying)?: return "engine \(MacDiag.error(underlying))"
        case .file(let underlying)?: return "file \(MacDiag.error(underlying))"
        case nil: return MacDiag.error(error)
        }
    }
}
