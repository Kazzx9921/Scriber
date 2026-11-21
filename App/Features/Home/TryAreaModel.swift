import Foundation
import Observation
import ScriberCore
import ScriberShared

/// One in-app test dictation, kept only for this launch so engines can be compared side by side.
struct Trial: Identifiable {
    enum Outcome {
        case success(PipelineResult)
        case failure(message: String, stt: STTProviderKind, polish: PolishProviderKind)
    }

    let id = UUID()
    let date: Date
    let outcome: Outcome
}

/// Drives the in-app mic pill on Home (tap to start, tap to finish) and collects results.
@MainActor
@Observable
final class TryAreaModel {
    enum State { case idle, recording, processing }

    private(set) var state: State = .idle
    private(set) var trials: [Trial] = DebugLaunch.demoData ? DemoData.trials : []

    @ObservationIgnored private var resultBefore: String?
    @ObservationIgnored private var errorBefore: String?
    @ObservationIgnored private var providers: (STTProviderKind, PolishProviderKind) = (.elevenLabsScribe, .off)
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    // MARK: Actions

    /// Tap to start, tap again to finish — same as the keyboard's mic pill.
    func toggle(engine: DictationEngine, settings: SettingsModel) {
        switch state {
        case .idle:
            resultBefore = Self.fingerprint(engine.lastResult)
            errorBefore = engine.lastErrorMessage
            providers = (settings.sttProvider, settings.polishProvider)
            engine.startRecording(request: DictationRequest())
            state = .recording
            Haptics.recordStart()
        case .recording:
            stop(engine: engine)
        case .processing:
            break
        }
    }

    func cancel(engine: DictationEngine) {
        guard state == .recording else { return }
        engine.cancelRecording()
        state = .idle
        Haptics.tap()
    }

    /// Hides the result card.
    func clear() { trials.removeAll() }

    /// Re-runs the pipeline on the audio the engine kept after a network/server failure.
    func retry(engine: DictationEngine) {
        guard state == .idle, engine.canRetry else { return }
        resultBefore = Self.fingerprint(engine.lastResult)
        errorBefore = engine.lastErrorMessage
        state = .processing
        engine.retryLastFailed()
        Haptics.tap()
    }

    // MARK: Engine updates

    func engineDidChange(phase: SessionPhase, engine: DictationEngine) {
        switch (state, phase) {
        case (.recording, .processing):
            state = .processing
        case (.recording, .failed):
            // Recording could not start or was cut off.
            finish(engine: engine, preferError: true, allowStale: false)
        case (.processing, .done):
            finish(engine: engine, preferError: false, allowStale: true)
        case (.processing, .failed):
            finish(engine: engine, preferError: true, allowStale: false)
        case (.processing, .idle):
            // Engine went straight back to idle (e.g. too short, or no separate done phase).
            finish(engine: engine, preferError: false, allowStale: false)
        default:
            break
        }
    }

    func engineDidReportError(_ message: String?, engine: DictationEngine) {
        guard state != .idle, let message, message != errorBefore else { return }
        if state == .processing {
            finish(engine: engine, preferError: true, allowStale: false)
        } else {
            // Recording could not start (e.g. audio session error).
            state = .idle
            append(.failure(message: message, stt: providers.0, polish: providers.1))
            Haptics.error()
        }
    }

    // MARK: Private

    private func stop(engine: DictationEngine) {
        guard state == .recording else { return }
        engine.stopRecordingAndTranscribe()
        state = .processing
        Haptics.recordStop()
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, self.state == .processing else { return }
            self.append(.failure(message: "等太久了，請再試一次", stt: self.providers.0, polish: self.providers.1))
            self.state = .idle
        }
    }

    /// `allowStale`: accept `lastResult` even if it looks identical to the one before this recording.
    private func finish(engine: DictationEngine, preferError: Bool, allowStale: Bool) {
        watchdog?.cancel()
        state = .idle
        let freshResult = Self.fingerprint(engine.lastResult) != resultBefore ? engine.lastResult : nil
        let freshError = engine.lastErrorMessage != errorBefore ? engine.lastErrorMessage : nil

        if preferError, let message = freshError ?? engine.lastErrorMessage {
            append(.failure(message: message, stt: providers.0, polish: providers.1))
            Haptics.error()
        } else if let result = freshResult ?? (allowStale ? engine.lastResult : nil) {
            append(.success(result))
            Haptics.success()
        } else if let message = freshError {
            append(.failure(message: message, stt: providers.0, polish: providers.1))
            Haptics.error()
        }
    }

    private func append(_ outcome: Trial.Outcome) {
        trials.insert(Trial(date: Date(), outcome: outcome), at: 0)
        if trials.count > 10 { trials.removeLast(trials.count - 10) }
    }

    private static func fingerprint(_ result: PipelineResult?) -> String? {
        guard let result else { return nil }
        return "\(result.rawTranscript.hashValue)|\(result.finalText.hashValue)|\(result.sttMillis)|\(result.polishMillis)"
    }
}
