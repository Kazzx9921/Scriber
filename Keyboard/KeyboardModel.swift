import Foundation
import Observation
import UIKit
import ScriberCore  // KeychainStore (shared keychain), for the translate availability check
import ScriberShared

/// Keyboard-side state machine. Two ways to record:
/// - **app**: the containing app records (warm through `SessionChannel` commands, or cold by
///   writing a launch request and opening scriber://session; the keyboard then adopts the
///   request the app is working on).
/// - **local**: experimental in-keyboard capture (`InKeyboardCapture`, iOS 26+), which also
///   runs the pipeline here. Anything that fails before audio arrives falls back to the app.
@MainActor
@Observable
final class KeyboardModel {
    enum Availability: Equatable {
        case ready
        /// Without Full Access there is no App Group and no open-URL: nothing works.
        case needsFullAccess
        /// No live background session: the next tap opens scriber://session (or records locally).
        case needsSession
    }

    enum Activity: Equatable {
        case idle
        case recording(toggle: Bool)
        case processing
        case failed(message: String, retryable: Bool)
    }

    enum SlideIntent: Equatable { case none, translate, cancel }

    /// Who records the request in flight.
    enum Path: String { case app, local }

    // MARK: Tuning
    /// Shorter presses are taps (toggle mode); longer ones are hold-to-talk.
    static let tapMaxDuration: TimeInterval = 0.35
    static let translateSlide: CGFloat = 56
    static let cancelSlide: CGFloat = 64
    /// The app must acknowledge a start within this, or it is considered gone.
    static let ackTimeout: TimeInterval = 1.5
    /// A result is inserted only if it was published (or, for older app builds, the request
    /// stopped) within this window: the keyboard may have been torn down and recreated, or the
    /// user may be in a different field by now.
    static let insertWindow: TimeInterval = 120
    /// A launch request the app has not acted on after this is given up (the app's
    /// `takeLaunchRequest` ignores requests older than 20 s).
    static let launchWindow: TimeInterval = 20
    /// Back in the host app with the launch request still untaken and no live app this long:
    /// the app is not going to start it (it can only start the microphone in front).
    static let untakenLaunchGrace: TimeInterval = 3
    static let launchPollInterval: TimeInterval = 0.25

    // MARK: Observable UI state
    private(set) var availability: Availability = .ready
    private(set) var activity: Activity = .idle {
        didSet { if activity != oldValue { activityDidChange() } }
    }
    private(set) var slide: SlideIntent = .none
    private(set) var isHolding = false
    var translateLocked = false
    private(set) var hasSelection = false
    private(set) var canUndo = false
    private(set) var returnKeyTitle = "換行"
    private(set) var showsGlobe = true
    private(set) var isLandscape = false
    /// The app was asked to start recording and has not picked the request up yet.
    private(set) var isOpeningApp = false
    /// In-keyboard capture is starting (no audio yet): wait before talking.
    private(set) var isStartingCapture = false
    /// Tapping records without switching apps (fresh heartbeat, or in-keyboard capture ready).
    private(set) var isWarm = false
    private(set) var forcesDarkAppearance = false
    /// What translate mode outputs (the same setting as the app's Settings screen).
    private(set) var translateLanguage = TranslateLanguage.find("en")
    /// The three languages of the translate key's long-press popup.
    private(set) var translateQuickLanguages: [TranslateLanguage] = []
    /// Non-nil when the keyboard can tell up front that translate cannot work.
    private(set) var translateBlocker: TranslateBlocker?
    /// A hint shown in the mic pill for a moment (translate language, translate unavailable).
    /// Wins over a failure while it lasts.
    private(set) var notice: KeyboardFeedback?
    /// Bumped for every problem shown, to shake the mic pill once.
    private(set) var shakeCount = 0

    // MARK: Private
    @ObservationIgnored let channel = SessionChannel()
    @ObservationIgnored let levels = LevelHistory()
    /// Long-press language popup of the translate key (observable on its own).
    @ObservationIgnored let translatePicker = TranslatePicker()
    @ObservationIgnored private var noticeToken = 0
    @ObservationIgnored private var failureDismissWork: DispatchWorkItem?
    @ObservationIgnored private(set) weak var controller: KeyboardViewController?
    @ObservationIgnored private let memory = KeyboardMemory()
    @ObservationIgnored private let haptics = KeyboardHaptics()
    @ObservationIgnored private let local = InKeyboardCapture()
    @ObservationIgnored private var request: DictationRequest?
    @ObservationIgnored private var requestPath: Path?
    @ObservationIgnored private var failedRequest: DictationRequest?
    @ObservationIgnored private var failedPath: Path?
    @ObservationIgnored private var pressStartedAt = Date.distantPast
    @ObservationIgnored private var pressIsHold = false
    @ObservationIgnored private var ackWork: DispatchWorkItem?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var launchPoll: Timer?
    @ObservationIgnored private var expiryWork: DispatchWorkItem?
    @ObservationIgnored private var lastInsertion: (text: String, replaced: String?)?
    @ObservationIgnored private var deleteTask: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var visibleSince = Date.distantPast
    /// A local result that finished while the keyboard was hidden (memory only, never on disk).
    @ObservationIgnored private var heldLocalResult: (id: String, text: String, at: Date)?
    @ObservationIgnored private var localReady = (available: false, reason: "not-checked")
    @ObservationIgnored private var lastLoggedState = ""
    @ObservationIgnored private var deferredLoggedID: String?
    @ObservationIgnored private let instance = String(UUID().uuidString.prefix(4))

    init(controller: KeyboardViewController) {
        self.controller = controller
        levels.provider = { [weak self] in self?.currentLevel() ?? 0 }
        channel.observeState { [weak self] state in
            self?.apply(state, source: "notify")
        }
        local.onEvent = { [weak self] event in self?.handleLocal(event) }
        translatePicker.onTap = { [weak self] in self?.translateKeyTapped() }
        translatePicker.openContext = { [weak self] in self?.translatePickerContext() }
        translatePicker.onChoose = { [weak self] language, via in self?.chooseTranslateLanguage(language, via: via) }
        translatePicker.onFeedback = { [weak self] feedback in
            switch feedback {
            case .opened: self?.haptics.light(); self?.haptics.prepareSelection()
            case .highlight: self?.haptics.selection()
            }
        }
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }
    private var hasFullAccess: Bool { controller?.hasFullAccess == true }

    // MARK: Lifecycle

    /// viewWillAppear. Reconciles with whatever happened while this instance was not listening
    /// (the keyboard can be destroyed and recreated mid-request). Text is inserted only once the
    /// keyboard is on screen (`didAppear`).
    func refresh() {
        guard let controller else { return }
        showsGlobe = controller.needsInputModeSwitchKey
        haptics.enabled = controller.hasFullAccess && AppSettings.shared.hapticsEnabled
        if controller.hasFullAccess { reloadTranslate() } // settings live in the App Group
        textContextChanged()
        localReady = local.availability(hasFullAccess: controller.hasFullAccess, checkKey: true)
        let state = channel.readState()
        let mic = InKeyboardCapture.microphonePermission()
        KBLog.log("appear kb=\(instance) fullAccess=\(controller.hasFullAccess) alive=\(state.isAlive()) local=\(localReady.reason) micApp=\(mic.published ?? "unpublished") micOwn=\(mic.own) pending=\(KBLog.id(memory.pending?.id)) \(KBLog.memory)")
        apply(state, source: "appear")
        updateLaunchWait(state)
        // viewDidAppear should follow; if a host never sends it, don't hold results forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.isVisible, self.controller?.view.window != nil else { return }
            KBLog.log("appear: no viewDidAppear after 0.8s, treating as visible")
            self.didAppear()
        }
    }

    /// viewDidAppear: now insertions reach the field the user sees.
    func didAppear() {
        guard !isVisible else { return }
        isVisible = true
        visibleSince = Date()
        let state = channel.readState()
        apply(state, source: "visible")
        updateLaunchWait(state)
        insertHeldLocalResult()
    }

    func setLandscape(_ landscape: Bool) {
        guard isLandscape != landscape else { return }
        isLandscape = landscape
        translatePicker.close(reason: "rotate") // its geometry was for the other height
    }

    func keyboardWillDisappear() {
        KBLog.log("disappear kb=\(instance) activity=\(describe(activity)) path=\(requestPath?.rawValue ?? "-") request=\(KBLog.id(request?.id))")
        isVisible = false
        deletePressEnded()
        stopLaunchPoll()
        translatePicker.reset()
        clearNotice()
        // A benign outcome is not worth showing again when the keyboard comes back.
        if failureFeedback?.kind == .benign { dismissError() }
        if requestPath == .local, isStartingCapture || activity.isRecording {
            // The extension is about to be torn down: stop and discard, never leave a capture behind.
            local.cancel(reason: "keyboard-hidden")
            endRequest()
            activity = .idle
        } else if requestPath == .app, activity.isRecording {
            // Keep what was said; the result is inserted if this field comes back in time.
            stop(translate: false)
        }
        if isHolding { isHolding = false; slide = .none }
    }

    func memoryWarning() {
        KBLog.log("memory warning kb=\(instance) path=\(requestPath?.rawValue ?? "-") local=\(local.phase.rawValue) \(KBLog.memory)")
    }

    func textContextChanged() {
        guard let proxy else { return }
        let selected = proxy.selectedText ?? ""
        let hasSelection = !selected.isEmpty
        if self.hasSelection != hasSelection { self.hasSelection = hasSelection }
        // The translate key is hidden while text is selected (the mic then rewrites the selection).
        if hasSelection { translatePicker.close(reason: "selection") }
        let title = Self.returnTitle(proxy.returnKeyType ?? .default)
        if returnKeyTitle != title { returnKeyTitle = title }
        let dark = proxy.keyboardAppearance == .dark
        if forcesDarkAppearance != dark { forcesDarkAppearance = dark }
    }

    // MARK: State from the app

    /// Called for every state the keyboard sees: Darwin notification, appear, the launch poll and
    /// the watchdog. Results and adoption depend only on the persisted pending request, never on
    /// what this instance happens to show.
    private func apply(_ state: SessionState, source: String) {
        logState(state, source: source)
        // 1. A result for our pending request is inserted whatever the UI shows.
        if state.phase == .done, let id = state.requestID, let text = state.resultText {
            insertResultIfPending(id: id, text: text)
        }
        // 2. The app works on our pending request but this instance does not track it: adopt.
        adoptIfNeeded(state)
        // 3. Transitions of the tracked app request.
        if requestPath == .app, let id = state.requestID, id == request?.id {
            switch state.phase {
            case .recording:
                ackWork?.cancel()
            case .processing:
                ackWork?.cancel()
                if activity.isRecording, !isHolding { activity = .processing }
            case .done:
                endRequest()
                activity = .idle
            case .failed:
                let retryable = channel.readRetryable()
                failedRequest = request
                failedPath = .app
                if !retryable { memory.pending = nil } // nothing left to come back for
                KBLog.log("app failed id=\(KBLog.id(id)) retryable=\(retryable)")
                endRequest()
                activity = .failed(message: state.errorMessage ?? "發生錯誤，請再試一次", retryable: retryable)
            case .idle:
                endRequest()
                activity = .idle
            }
        } else if request == nil, state.phase == .failed, let id = state.requestID, id == memory.pending?.id,
                  !isFailureShown(for: id) {
            // Our pending request failed while this instance was not tracking it.
            let retryable = channel.readRetryable()
            failedRequest = memory.pendingRequest
            failedPath = .app
            if !retryable { memory.pending = nil }
            KBLog.log("app failed (while away) id=\(KBLog.id(id)) retryable=\(retryable)")
            isOpeningApp = false
            activity = .failed(message: state.errorMessage ?? "發生錯誤，請再試一次", retryable: retryable)
        }
        updateAvailability(state)
    }

    private func isFailureShown(for id: String) -> Bool {
        if case .failed = activity, failedRequest?.id == id { return true }
        return false
    }

    private func adoptIfNeeded(_ state: SessionState) {
        guard request == nil, let pending = memory.pending, let id = state.requestID, pending.id == id else { return }
        switch state.phase {
        case .recording:
            request = pending.request
            requestPath = .app
            activity = .recording(toggle: true) // finger is no longer down; tap to finish
            isOpeningApp = false
            stopLaunchPoll()
            startWatchdog()
            KBLog.log("adopt id=\(KBLog.id(id)) phase=recording via=\(pending.via ?? "?") age=\(KBLog.millis(since: pending.sentAt))ms")
        case .processing:
            request = pending.request
            requestPath = .app
            activity = .processing
            isOpeningApp = false
            stopLaunchPoll()
            startWatchdog()
            KBLog.log("adopt id=\(KBLog.id(id)) phase=processing via=\(pending.via ?? "?") age=\(KBLog.millis(since: pending.sentAt))ms")
        case .idle:
            // The app dropped it (cancelled in the app, or its session ended first).
            KBLog.log("pending id=\(KBLog.id(id)) dropped by the app (idle)")
            memory.pending = nil
            isOpeningApp = false
            stopLaunchPoll()
        case .done, .failed:
            isOpeningApp = false
            stopLaunchPoll()
        }
    }

    private func updateAvailability(_ state: SessionState) {
        let next: Availability
        if !hasFullAccess {
            next = .needsFullAccess
        } else if state.isAlive() || request != nil {
            // While a request is in flight the watchdog (app) or the capture (local) decides.
            next = .ready
        } else {
            next = .needsSession
        }
        if availability != next {
            KBLog.log("availability \(availability) → \(next) alive=\(state.isAlive()) request=\(KBLog.id(request?.id))")
            availability = next
        }
        let warm = hasFullAccess && (state.isAlive() || localReady.available)
        if isWarm != warm { isWarm = warm }
        scheduleExpiryCheck(state)
    }

    /// The glyph must turn cold when the session expires by itself; one timer at `expiresAt`
    /// (no polling while idle).
    private func scheduleExpiryCheck(_ state: SessionState) {
        expiryWork?.cancel()
        expiryWork = nil
        guard state.isAlive(), let expires = state.expiresAt, expires > Date() else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateAvailability(self.channel.readState())
            }
        }
        expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + expires.timeIntervalSinceNow + 0.5, execute: work)
    }

    // MARK: Waiting for the app after opening it

    /// A launch request this instance does not track yet and the app has not reported on.
    private func isAwaitingLaunch(_ state: SessionState) -> Bool {
        guard request == nil, let pending = memory.pending, pending.via == KeyboardMemory.viaLaunch else { return false }
        return state.requestID != pending.id
    }

    /// Back from the app (or still on screen right after opening it): poll briefly so the
    /// request is adopted the moment the app publishes it, even if a notification was missed
    /// or the state was read a moment too early.
    private func updateLaunchWait(_ state: SessionState) {
        guard isAwaitingLaunch(state), let pending = memory.pending else {
            stopLaunchPoll()
            // No launch left to wait for (adopted, answered, dropped or never written).
            if isOpeningApp, request != nil || memory.pending?.via != KeyboardMemory.viaLaunch { isOpeningApp = false }
            return
        }
        guard Date().timeIntervalSince(pending.sentAt) < Self.launchWindow else {
            giveUpLaunch(reason: "expired")
            return
        }
        isOpeningApp = true
        guard isVisible || controller?.view.window != nil, launchPoll == nil else { return }
        KBLog.log("waiting for app id=\(KBLog.id(pending.id)) age=\(KBLog.millis(since: pending.sentAt))ms taken=\(channel.peekLaunchRequest()?.id != pending.id)")
        let timer = Timer(timeInterval: Self.launchPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.launchPollTick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        launchPoll = timer
    }

    private func launchPollTick() {
        let state = channel.readState()
        apply(state, source: "poll")
        guard isAwaitingLaunch(state), let pending = memory.pending else {
            stopLaunchPoll()
            return
        }
        let age = Date().timeIntervalSince(pending.sentAt)
        let untaken = channel.peekLaunchRequest()?.id == pending.id
        if age >= Self.launchWindow {
            giveUpLaunch(reason: "no-state-after-\(Int(age))s taken=\(!untaken)")
        } else if untaken, isVisible, !state.isAlive(),
                  Date().timeIntervalSince(max(visibleSince, pending.sentAt)) >= Self.untakenLaunchGrace {
            giveUpLaunch(reason: "untaken-while-back age=\(Int(age))s")
        }
    }

    private func stopLaunchPoll() {
        launchPoll?.invalidate()
        launchPoll = nil
    }

    private func giveUpLaunch(reason: String) {
        stopLaunchPoll()
        guard let pending = memory.pending else { return }
        KBLog.log("watchdog give up launch id=\(KBLog.id(pending.id)) reason=\(reason)")
        channel.withdrawLaunchRequest(id: pending.id) // so the app does not start it later by surprise
        memory.pending = nil
        isOpeningApp = false
        activity = .failed(message: "Scriber 沒有開始錄音，請再點一下", retryable: false)
    }

    // MARK: Mic gestures

    /// One tap starts listening, the next tap finishes. There is no hold-to-talk.
    func micTapped() {
        guard hasFullAccess else {
            KBLog.log("tap ignored: no full access")
            return
        }
        translatePicker.close(reason: "mic")
        let state = channel.readState()
        if isAwaitingLaunch(state) {
            // Double taps and impatient taps while the app is starting: harmless. Re-check first,
            // the app may have just published the request.
            apply(state, source: "tap")
            if isAwaitingLaunch(state) {
                KBLog.log("tap ignored: waiting for the app to start id=\(KBLog.id(memory.pending?.id))")
                updateLaunchWait(state)
                return
            }
        }
        if isStartingCapture {
            KBLog.log("tap: stop while local capture is starting")
            local.stop()
            return
        }
        switch activity {
        case .recording:
            KBLog.log("tap: stop path=\(requestPath?.rawValue ?? "-") id=\(KBLog.id(request?.id))")
            if requestPath == .local { local.stop() } else { stop(translate: false) }
            return
        case .processing:
            KBLog.log("tap ignored: processing")
            return
        case .idle, .failed:
            break
        }
        if isOpeningApp {
            KBLog.log("tap ignored: opening the app")
            return
        }
        let next = makeRequest()
        // Liveness is re-read at the tap: the cached availability can be stale.
        if state.isAlive() {
            KBLog.log("tap: start path=app-warm id=\(KBLog.id(next.id)) mode=\(next.mode.rawValue)")
            startViaApp(next)
            return
        }
        localReady = local.availability(hasFullAccess: hasFullAccess, checkKey: true)
        if localReady.available, let host = controller?.view {
            KBLog.log("tap: start path=local id=\(KBLog.id(next.id)) mode=\(next.mode.rawValue) \(KBLog.memory)")
            startLocal(next, host: host)
            return
        }
        KBLog.log("tap: start path=open-app id=\(KBLog.id(next.id)) mode=\(next.mode.rawValue) local=\(localReady.reason)")
        availability = .needsSession
        launchAndRecord(next)
    }

    private func makeRequest() -> DictationRequest {
        let selected = (proxy?.selectedText).flatMap { $0.isEmpty ? nil : $0 }
        let mode: DictationMode = selected != nil ? .edit : (translateLocked ? .translate : .dictate)
        return DictationRequest(mode: mode, selectedText: selected, fieldHint: fieldHint())
    }

    /// The app is not running: leave the request for it and open it. It starts recording as
    /// soon as it is in front; this keyboard adopts the request as soon as the app reports on it
    /// (see `apply` / `updateLaunchWait`).
    private func launchAndRecord(_ next: DictationRequest) {
        guard hasFullAccess, !isOpeningApp else {
            KBLog.log("launch skipped: already opening the app")
            return
        }
        failedRequest = nil
        failedPath = nil
        if case .failed = activity { activity = .idle }
        memory.setPending(next, via: KeyboardMemory.viaLaunch)
        levels.reset()
        channel.writeLaunchRequest(next)
        KBLog.log("launch request written id=\(KBLog.id(next.id))")
        launchApp()
    }

    // MARK: Actions

    func cancel() {
        guard let request else {
            if case .failed = activity { dismissError() }
            return
        }
        KBLog.log("cancel path=\(requestPath?.rawValue ?? "-") id=\(KBLog.id(request.id))")
        if requestPath == .local {
            local.cancel(reason: "user")
        } else {
            channel.send(.cancel, request: request)
            memory.pending = nil
        }
        endRequest()
        activity = .idle
        haptics.light()
    }

    /// Re-runs a retryable failure on the kept audio. False when there is nothing to retry.
    @discardableResult
    func retry() -> Bool {
        guard case .failed(_, true) = activity, let failed = failedRequest else { return false }
        if failedPath == .local {
            guard let retried = local.retry() else { return false }
            request = retried
            requestPath = .local
            activity = .processing
            return true
        }
        KBLog.log("retry path=app id=\(KBLog.id(failed.id))")
        request = failed
        requestPath = .app
        memory.pending = KeyboardMemory.Pending(id: failed.id, sentAt: Date(), request: failed,
                                                via: KeyboardMemory.viaCommand, stoppedAt: Date()) // fresh window
        channel.send(.stop, request: failed)
        activity = .processing
        startWatchdog()
        return true
    }

    func dismissError() {
        if case .failed = activity { activity = .idle }
        if failedPath == .local { local.discardKept() }
        failedRequest = nil
        failedPath = nil
        if request == nil { memory.pending = nil }
    }

    // MARK: Feedback in the mic pill

    /// The pill content for the current `.failed` activity (short label; see `KeyboardFeedback`).
    var failureFeedback: KeyboardFeedback? {
        guard case .failed(let message, let retryable) = activity else { return nil }
        return KeyboardFeedback.forFailure(message: message, retryable: retryable)
    }

    /// What the mic pill shows instead of the mic glyph while idle or failed.
    var feedback: KeyboardFeedback? { notice ?? failureFeedback }

    /// The left round key turns into a dismiss key for failures that wait for the user.
    var showsDismissKey: Bool {
        guard let kind = failureFeedback?.kind else { return false }
        return kind == .retry || kind == .needsSetup
    }

    /// The mic pill: dictation normally; retry / open Scriber / start over while it shows feedback.
    func pillTapped() {
        if let shown = notice {
            clearNotice()
            if shown.kind == .needsSetup {
                openAppForSetup(type: shown.type)
                return
            }
        }
        if let failure = failureFeedback {
            switch failure.kind {
            case .retry:
                KBLog.log("pill: retry type=\(failure.type)")
                if !retry() { dismissError() } // nothing kept any more: back to the idle mic
                return
            case .needsSetup:
                dismissError()
                openAppForSetup(type: failure.type)
                return
            case .info, .benign, .failure:
                dismissError() // and dictate again right away
            }
        }
        micTapped()
    }

    private func activityDidChange() {
        failureDismissWork?.cancel()
        failureDismissWork = nil
        guard let failure = failureFeedback else { return }
        KBLog.log("feedback type=\(failure.type) kind=\(failure.kind.rawValue)")
        present(failure)
        guard let delay = failure.dismissAfter else { return }
        let shown = activity
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activity == shown else { return }
                self.dismissError()
            }
        }
        failureDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Haptic, shake and VoiceOver announcement (the full sentence) for newly shown feedback.
    private func present(_ feedback: KeyboardFeedback) {
        switch feedback.kind {
        case .info: break
        case .benign: haptics.warning()
        case .failure, .retry, .needsSetup: haptics.error()
        }
        if feedback.isProblem { shakeCount += 1 }
        UIAccessibility.post(notification: .announcement, argument: feedback.spoken)
    }

    private func showNotice(_ feedback: KeyboardFeedback) {
        noticeToken += 1
        let token = noticeToken
        notice = feedback
        present(feedback)
        guard let delay = feedback.dismissAfter else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeToken == token else { return }
                self.notice = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearNotice() {
        noticeToken += 1
        if notice != nil { notice = nil }
    }

    /// "Needs setup": bring Scriber forward so the user can fix it. Not scriber://session, which
    /// would start a recording session; the app does not route "settings" yet, so it simply
    /// comes to the front on its current screen.
    private func openAppForSetup(type: String) {
        guard hasFullAccess, let url = URL(string: "\(AppGroup.urlScheme)://settings") else { return }
        KBLog.log("open app for setup type=\(type)")
        haptics.light()
        controller?.openContainingApp(url) { [weak self] opened in
            guard let self else { return }
            KBLog.log("open app for setup result=\(opened)")
            if !opened { self.showNotice(KeyboardFeedback.openAppFailed) }
        }
    }

    // MARK: Translate key

    /// Why translate cannot work, as far as the keyboard can tell up front.
    enum TranslateBlocker: String, Equatable {
        case polishOff = "polish-off"
        case polishKeyMissing = "polish-key-missing"
    }

    /// Re-reads the language, the quick languages and whether translate can work (App Group
    /// defaults + one shared-keychain read). Called on appear and on every translate-key action.
    private func reloadTranslate() {
        let settings = AppSettings.shared
        let language = Self.currentTranslateLanguage(settings)
        if translateLanguage != language { translateLanguage = language }
        let quick = settings.translateQuickLanguageIDs.map(TranslateLanguage.find)
        if translateQuickLanguages != quick { translateQuickLanguages = quick }
        let blocker = Self.translateBlocker(settings)
        if translateBlocker != blocker {
            KBLog.log("translate availability \(translateBlocker?.rawValue ?? "ok") → \(blocker?.rawValue ?? "ok")")
            translateBlocker = blocker
        }
        if let blocker, translateLocked {
            translateLocked = false // a translate request would only fail
            KBLog.log("translate off reason=\(blocker.rawValue)")
        }
    }

    /// The pipeline reads `translateTarget`; `translateLanguageID` is newer and may be absent or
    /// out of step (older app builds wrote only the target). Trust the target when they disagree.
    private static func currentTranslateLanguage(_ settings: AppSettings) -> TranslateLanguage {
        let byID = TranslateLanguage.find(settings.translateLanguageID)
        let target = settings.translateTarget
        if byID.promptName == target { return byID }
        return TranslateLanguage.all.first { $0.promptName == target } ?? byID
    }

    private static func translateBlocker(_ settings: AppSettings) -> TranslateBlocker? {
        // Translate works with any LLM key, whether or not "AI 潤飾" is on (the pipeline picks
        // the polish provider if one is selected, otherwise whichever key exists).
        let keys = KeychainStore.shared
        if keys.hasKey(for: .groq) || keys.hasKey(for: .anthropic) { return nil }
        // "Missing" is only trustworthy when the keychain group shared with the app is in use;
        // otherwise the keyboard cannot see the app's keys at all, and the pipeline reports the
        // real problem if there is one.
        return keys.accessGroup != nil ? .polishKeyMissing : nil
    }

    private func showTranslateBlocked(_ blocker: TranslateBlocker) {
        KBLog.log("translate unavailable reason=\(blocker.rawValue)")
        showNotice(blocker == .polishOff ? KeyboardFeedback.translateNeedsPolish() : KeyboardFeedback.translateNeedsKey())
    }

    /// Tap: translate on / off.
    func translateKeyTapped() {
        guard hasFullAccess else { return }
        reloadTranslate()
        if let translateBlocker {
            showTranslateBlocked(translateBlocker)
            return
        }
        translateLocked.toggle()
        haptics.key()
        KBLog.log("translate \(translateLocked ? "on" : "off") lang=\(translateLanguage.id) via=tap")
        if translateLocked {
            showNotice(KeyboardFeedback.translateOn(languageName: translateLanguage.displayName))
        } else {
            clearNotice()
            UIAccessibility.post(notification: .announcement, argument: "已關閉翻譯")
        }
    }

    /// Long-press popup, VoiceOver action: choose the language and turn translate on.
    func chooseTranslateLanguage(_ language: TranslateLanguage, via: String) {
        guard hasFullAccess else { return }
        reloadTranslate()
        if let translateBlocker {
            showTranslateBlocked(translateBlocker)
            return
        }
        let previous = translateLanguage.id
        let wasOn = translateLocked
        AppSettings.shared.translateLanguageID = language.id // also sets translateTarget
        translateLanguage = language
        translateLocked = true
        KBLog.log("translate lang \(previous)→\(language.id) on=\(wasOn)→true via=\(via)")
        showNotice(KeyboardFeedback.translateOn(languageName: language.displayName))
    }

    /// The long-press popup is about to open: its options, or nil (and an explanation) when
    /// translate cannot work.
    private func translatePickerContext() -> (languages: [TranslateLanguage], compact: Bool)? {
        guard hasFullAccess else { return nil }
        reloadTranslate()
        if let translateBlocker {
            showTranslateBlocked(translateBlocker)
            return nil
        }
        guard !translateQuickLanguages.isEmpty else { return nil }
        KBLog.log("translate picker open options=\(translateQuickLanguages.map(\.id).joined(separator: ",")) current=\(translateLanguage.id)")
        return (translateQuickLanguages, isLandscape)
    }

    func launchApp() {
        guard hasFullAccess, let url = URL(string: "\(AppGroup.urlScheme)://session") else { return }
        isOpeningApp = true
        haptics.light()
        controller?.openContainingApp(url) { [weak self] opened in
            guard let self else { return }
            KBLog.log("open app result=\(opened) pending=\(KBLog.id(self.memory.pending?.id))")
            if opened {
                // Usually the keyboard disappears now; if it stays on screen, the poll notices
                // the app picking the request up (or not).
                self.updateLaunchWait(self.channel.readState())
            } else {
                if let pending = self.memory.pending, pending.via == KeyboardMemory.viaLaunch {
                    self.channel.withdrawLaunchRequest(id: pending.id)
                    self.memory.pending = nil
                }
                self.isOpeningApp = false
                self.activity = .failed(message: "無法自動打開 Scriber，請手動開啟 Scriber App", retryable: false)
            }
        }
    }

    func undo() {
        guard let last = lastInsertion, let proxy else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        // Hosts may only expose part of the document; accept a truncated context that is
        // itself the tail of what we inserted.
        let matches = before.hasSuffix(last.text) || (!before.isEmpty && last.text.hasSuffix(before))
        lastInsertion = nil
        canUndo = false
        guard matches else { return }
        for _ in 0..<last.text.count { proxy.deleteBackward() }
        if let replaced = last.replaced { proxy.insertText(replaced) }
        haptics.light()
    }

    func insertSpace() {
        proxy?.insertText(" ")
        didTypeManually()
    }

    func insertReturn() {
        proxy?.insertText("\n")
        didTypeManually()
    }

    func deletePressBegan() {
        deleteTask?.cancel()
        proxy?.deleteBackward()
        didTypeManually()
        deleteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            var count = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.proxy?.deleteBackward()
                count += 1
                try? await Task.sleep(for: .milliseconds(count > 20 ? 45 : 90))
            }
        }
    }

    func deletePressEnded() {
        deleteTask?.cancel()
        deleteTask = nil
    }

    // MARK: App path

    private func startViaApp(_ next: DictationRequest) {
        request = next
        requestPath = .app
        failedRequest = nil
        failedPath = nil
        memory.setPending(next, via: KeyboardMemory.viaCommand)
        levels.reset()
        channel.send(.start, request: next)
        activity = .recording(toggle: true)
        haptics.press()
        scheduleAck(for: next.id)
        startWatchdog()
    }

    private func stop(translate: Bool) {
        guard var current = request, requestPath == .app else { return }
        if current.mode != .edit, translate || translateLocked { current.mode = .translate }
        request = current
        memory.setPending(current, via: memory.pending?.via ?? KeyboardMemory.viaCommand, stoppedAt: Date())
        channel.send(.stop, request: current)
        KBLog.log("stop sent id=\(KBLog.id(current.id)) mode=\(current.mode.rawValue)")
        activity = .processing
        haptics.light()
    }

    private func endRequest() {
        ackWork?.cancel()
        ackWork = nil
        watchdog?.invalidate()
        watchdog = nil
        request = nil
        requestPath = nil
        isStartingCapture = false
    }

    private func scheduleAck(for id: String) {
        ackWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.request?.id == id else { return }
                let state = self.channel.readState()
                if state.requestID == id, state.phase != .idle { return }
                self.giveUp(message: "Scriber 沒有回應，請點一下重新啟動", reason: "ack-timeout")
            }
        }
        ackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ackTimeout, execute: work)
    }

    /// Runs only while an app request is in flight: notices an app that died mid-request.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.request?.id, self.requestPath == .app else { return }
                let state = self.channel.readState()
                if state.requestID == id, state.phase == .done || state.phase == .failed || state.phase == .idle {
                    self.apply(state, source: "watchdog") // a missed notification
                } else if !state.isAlive(tolerance: 4) {
                    self.giveUp(message: "Scriber 已停止，請點一下重新啟動", reason: "app-not-alive")
                }
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func giveUp(message: String, reason: String) {
        KBLog.log("watchdog give up id=\(KBLog.id(request?.id)) reason=\(reason)")
        // Cancel on the app side too, so an app that was only suspended does not finish this
        // request later and surprise the user; then forget it here.
        if let request { channel.send(.cancel, request: request) }
        memory.pending = nil
        endRequest()
        isHolding = false
        slide = .none
        activity = .failed(message: message, retryable: false)
        availability = hasFullAccess ? .needsSession : .needsFullAccess
    }

    // MARK: Local path (in-keyboard capture)

    private func startLocal(_ next: DictationRequest, host: UIView) {
        request = next
        requestPath = .local
        failedRequest = nil
        failedPath = nil
        levels.reset()
        isStartingCapture = true
        activity = .recording(toggle: true)
        haptics.press()
        local.start(next, host: host)
    }

    private func handleLocal(_ event: InKeyboardCapture.Event) {
        switch event {
        case .listening:
            isStartingCapture = false
        case .fallback(let original, let reason):
            // Same tap, other path: nothing was captured, so the user only waited ≤ ~1.5 s.
            endRequest()
            activity = .idle
            localReady = (false, "fallback \(reason)")
            let state = channel.readState()
            if state.isAlive() {
                KBLog.log("local fallback served by app-warm id=\(KBLog.id(original.id))")
                startViaApp(original)
            } else {
                KBLog.log("local fallback served by open-app id=\(KBLog.id(original.id))")
                launchAndRecord(original)
            }
            updateAvailability(state)
        case .endedByItself:
            local.stop()
        case .processing:
            isStartingCapture = false
            if requestPath == .local { activity = .processing }
        case .finished(let finished, let text):
            if request?.id == finished.id { endRequest() }
            activity = .idle
            insertLocal(text, id: finished.id)
        case .failed(let failed, let message, let retryable):
            if request?.id == failed.id { endRequest() }
            failedRequest = failed
            failedPath = .local
            activity = .failed(message: message, retryable: retryable)
        }
    }

    private func insertLocal(_ text: String, id: String) {
        guard isVisible, proxy != nil else {
            heldLocalResult = (id, text, Date())
            KBLog.log("insert deferred id=\(KBLog.id(id)) path=local reason=keyboard-hidden len=\(text.count)")
            return
        }
        performInsert(text, id: id, path: "local", age: 0)
    }

    private func insertHeldLocalResult() {
        guard let held = heldLocalResult else { return }
        heldLocalResult = nil
        let age = Date().timeIntervalSince(held.at)
        guard age < Self.insertWindow else {
            KBLog.log("insert skipped id=\(KBLog.id(held.id)) path=local reason=stale age=\(Int(age))s (kept in history)")
            return
        }
        performInsert(held.text, id: held.id, path: "local", age: age)
    }

    private func currentLevel() -> Float {
        requestPath == .local ? local.level : channel.readLevel()
    }

    // MARK: Inserting

    private func insertResultIfPending(id: String, text: String) {
        guard let pending = memory.pending, pending.id == id else { return } // not ours, or already handled
        if id == memory.lastInsertedID {
            KBLog.log("insert skipped id=\(KBLog.id(id)) reason=already-inserted")
            memory.pending = nil
            return
        }
        // Age from when the app published the result; older app builds: from the stop / tap.
        let published = channel.readStateChangedAt()
        let reference = published ?? pending.stoppedAt ?? pending.sentAt
        let age = Date().timeIntervalSince(reference)
        guard age < Self.insertWindow else {
            KBLog.log("insert skipped id=\(KBLog.id(id)) reason=stale age=\(Int(age))s from=\(published != nil ? "published" : (pending.stoppedAt != nil ? "stop" : "tap"))")
            memory.pending = nil
            return
        }
        guard isVisible else {
            // While the keyboard is off screen the proxy may not reach the field: insert on return.
            if deferredLoggedID != id {
                deferredLoggedID = id
                KBLog.log("insert deferred id=\(KBLog.id(id)) path=app reason=keyboard-hidden len=\(text.count)")
            }
            return
        }
        guard proxy != nil else {
            KBLog.log("insert deferred id=\(KBLog.id(id)) reason=no-proxy")
            return
        }
        // Persist first: if we crash right after inserting, we must not insert again.
        memory.lastInsertedID = id
        memory.pending = nil
        performInsert(text, id: id, path: "app", age: age)
    }

    private func performInsert(_ text: String, id: String, path: String, age: TimeInterval) {
        guard let proxy else { return }
        let selected = proxy.selectedText ?? ""
        proxy.insertText(text)
        lastInsertion = (text, selected.isEmpty ? nil : selected)
        canUndo = true
        if case .failed = activity { activity = .idle }
        if activity == .processing { activity = .idle }
        isOpeningApp = false
        KBLog.log("insert id=\(KBLog.id(id)) path=\(path) len=\(text.count) replaced=\(selected.count) age=\(Int(age * 1000))ms")
        haptics.success()
    }

    private func didTypeManually() {
        if canUndo { canUndo = false }
        lastInsertion = nil
        haptics.key()
    }

    private func logState(_ state: SessionState, source: String) {
        let summary = "\(state.phase.rawValue)/\(KBLog.id(state.requestID))/alive=\(state.isAlive())"
        guard summary != lastLoggedState else { return }
        lastLoggedState = summary
        KBLog.log("state \(summary) src=\(source) pending=\(KBLog.id(memory.pending?.id)) tracked=\(KBLog.id(request?.id))")
    }

    private func describe(_ activity: Activity) -> String {
        switch activity {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .failed(_, let retryable): return "failed(retryable=\(retryable))"
        }
    }

    private func fieldHint() -> FieldHint {
        guard let proxy else { return .general }
        let contentType: UITextContentType? = proxy.textContentType.flatMap { $0 }
        if contentType == .emailAddress { return .email }
        if contentType == .URL { return .url }
        switch proxy.keyboardType ?? .default {
        case .emailAddress: return .email
        case .URL: return .url
        case .webSearch: return .search
        case .twitter: return .chat
        default: break
        }
        switch proxy.returnKeyType ?? .default {
        case .search, .google, .yahoo: return .search
        case .send: return .chat
        default: return .general
        }
    }

    #if DEBUG
    /// Layout review only (renders each state for screenshots); the keyboard never calls it.
    func debugShow(availability: Availability, activity: Activity, slide: SlideIntent = .none,
                   holding: Bool = false, hasSelection: Bool = false, canUndo: Bool = false,
                   translateLocked: Bool = false, landscape: Bool = false, warm: Bool = true) {
        self.availability = availability
        self.activity = activity
        self.slide = slide
        self.isHolding = holding
        self.hasSelection = hasSelection
        self.canUndo = canUndo
        self.translateLocked = translateLocked
        self.isLandscape = landscape
        self.isWarm = warm
    }
    #endif

    static func returnTitle(_ type: UIReturnKeyType) -> String {
        switch type {
        case .go: return "前往"
        case .google, .yahoo, .search: return "搜尋"
        case .join: return "加入"
        case .next: return "下一步"
        case .route: return "路線"
        case .send: return "傳送"
        case .done: return "完成"
        case .emergencyCall: return "緊急電話"
        case .continue: return "繼續"
        default: return "換行"
        }
    }
}

private extension KeyboardModel.Activity {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

// MARK: - Persistence that must survive the keyboard being recreated

/// Keyboard-only keys in the App Group defaults (the app never reads them). Only ids, times and
/// the request (whose `selectedText` the app needs anyway) — never results.
struct KeyboardMemory {
    static let viaLaunch = "launch"
    static let viaCommand = "command"

    struct Pending: Codable {
        var id: String
        var sentAt: Date
        var request: DictationRequest
        /// "launch" (opened the app) or "command" (warm app). Optional: older builds lack it.
        var via: String?
        /// When the keyboard sent `.stop`.
        var stoppedAt: Date?
    }

    private var defaults: UserDefaults { AppGroup.defaults }
    private static let pendingKey = "keyboard.pendingRequest"
    private static let lastInsertedKey = "keyboard.lastInsertedRequestID"

    var pending: Pending? {
        get {
            guard let data = defaults.data(forKey: Self.pendingKey) else { return nil }
            return try? JSONDecoder().decode(Pending.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.pendingKey)
            } else {
                defaults.removeObject(forKey: Self.pendingKey)
            }
        }
    }

    var pendingRequest: DictationRequest? { pending?.request }

    /// Keeps the original send time (and route) when the same request is updated (stop, retry).
    func setPending(_ request: DictationRequest, via: String, stoppedAt: Date? = nil) {
        let current = pending?.id == request.id ? pending : nil
        pending = Pending(id: request.id, sentAt: current?.sentAt ?? Date(), request: request,
                          via: current?.via ?? via, stoppedAt: stoppedAt ?? current?.stoppedAt)
    }

    var lastInsertedID: String? {
        get { defaults.string(forKey: Self.lastInsertedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.lastInsertedKey) }
    }
}

// MARK: - Haptics

@MainActor
final class KeyboardHaptics {
    /// Haptics in a keyboard need Full Access; also respects the app setting.
    var enabled = false
    private lazy var medium = UIImpactFeedbackGenerator(style: .medium)
    private lazy var soft = UIImpactFeedbackGenerator(style: .light)
    private lazy var selectionGenerator = UISelectionFeedbackGenerator()
    private lazy var notification = UINotificationFeedbackGenerator()

    func press() { guard enabled else { return }; medium.impactOccurred() }
    func light() { guard enabled else { return }; soft.impactOccurred() }
    func key() { guard enabled else { return }; soft.impactOccurred(intensity: 0.6) }
    func selection() { guard enabled else { return }; selectionGenerator.selectionChanged() }
    /// Lowers the latency of the next `selection()` (the popup's ticks while dragging).
    func prepareSelection() { guard enabled else { return }; selectionGenerator.prepare() }
    func success() { guard enabled else { return }; notification.notificationOccurred(.success) }
    func warning() { guard enabled else { return }; notification.notificationOccurred(.warning) }
    func error() { guard enabled else { return }; notification.notificationOccurred(.error) }
}

// MARK: - Level history for the waveform

/// Not observable on purpose: the waveform pulls from it inside a TimelineView that only exists
/// while recording, so no SwiftUI invalidation (and no timer) happens when idle.
@MainActor
final class LevelHistory {
    static let capacity = 28
    /// The app's level slot or the in-keyboard recorder, whichever records.
    var provider: (() -> Float)?
    private(set) var samples = [Float](repeating: 0, count: LevelHistory.capacity)
    private var lastSample = Date.distantPast

    func reset() {
        samples = [Float](repeating: 0, count: Self.capacity)
        lastSample = .distantPast
    }

    /// Advances at most ~30 times a second however many views ask.
    func advance(to date: Date) -> [Float] {
        guard date.timeIntervalSince(lastSample) >= 1.0 / 30 else { return samples }
        lastSample = date
        let level = provider?() ?? 0
        samples.removeFirst()
        samples.append(level)
        return samples
    }
}
