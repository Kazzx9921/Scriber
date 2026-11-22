import AVFoundation
import Observation
import ScriberCore
import ScriberShared

/// 設定 → 音訊 → 麥克風 → 測試: runs the chosen microphone for a few seconds, on request only, and
/// shows its level. Never runs on its own, never while dictating (a recording stops it), and is
/// only offered when microphone access is already granted (so it never prompts).
@MainActor
@Observable
final class MicLevelTest {
    enum State: Equatable {
        case idle
        case running
        case failed
    }

    static let seconds: TimeInterval = 5
    /// The test that is running, so a recording can stop it first.
    private(set) static weak var running: MicLevelTest?

    private(set) var state: State = .idle
    /// 0...1, smoothed.
    private(set) var level: Float = 0
    /// Which input the test used (fallback shows as a caption).
    private(set) var route: InputRoute?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var endWork: DispatchWorkItem?
    @ObservationIgnored private let meter = LevelMeterBox()
    @ObservationIgnored private let isSample: Bool

    init() {
        isSample = false
    }

    /// Snapshot renders: a frozen state.
    init(sample state: State, level: Float = 0) {
        isSample = true
        self.state = state
        self.level = level
    }

    var isRunning: Bool { state == .running }

    func start(pinnedUID: String?) {
        guard !isSample else { return }
        stop()
        meter.reset()
        let meter = self.meter
        do {
            let started = try InputEngine.start(pinnedUID: pinnedUID, tag: "mic-test") { buffer in
                meter.ingest(buffer)
            }
            engine = started.engine
            route = started.route
            state = .running
            Self.running = self
            DiagLog.log("audio", "mic test started \(started.description) route=\(started.route.logDescription)")
        } catch {
            state = .failed
            DiagLog.log("audio", "mic test failed \(InputEngine.describe(error))")
            return
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = self.meter.value
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.stop() }
        }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.seconds, execute: work)
    }

    func stop() {
        guard !isSample else { return }
        endWork?.cancel()
        endWork = nil
        timer?.invalidate()
        timer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            DiagLog.log("audio", "mic test stopped peak=\(String(format: "%.2f", meter.peak))")
        }
        if state == .running { state = .idle }
        if Self.running === self { Self.running = nil }
        level = 0
    }
}

/// Level from the audio thread, read by the UI timer.
private final class LevelMeterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var smoothed: Float = 0
    private var loudest: Float = 0

    var value: Float {
        lock.lock(); defer { lock.unlock() }
        return smoothed
    }

    var peak: Float {
        lock.lock(); defer { lock.unlock() }
        return loudest
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        smoothed = 0
        loudest = 0
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        let level = PCMLevel.level(rms: PCMLevel.rms(samples))
        lock.lock(); defer { lock.unlock() }
        smoothed = level > smoothed ? level : smoothed * 0.8 + level * 0.2
        loudest = max(loudest, level)
    }
}
