import AVFoundation
import ScriberShared

/// An output-only AVAudioEngine that renders silence. Used by the `.outputOnly` standby to keep
/// the process running (`UIBackgroundModes: audio`) while the microphone is completely off.
///
/// Why an engine and not an AVAudioPlayer looping a silent file: the engine never touches
/// `inputNode`, so its I/O unit has input disabled (no microphone use, no orange indicator), it
/// needs no bundled asset, and its configuration-change notification tells us exactly when the
/// system stopped it. It never becomes the "Now Playing" app: the session is mixable and nothing
/// publishes now-playing info, so the user's music keeps its lock-screen controls.
///
/// Built lazily: on a headless simulator merely touching an engine's I/O node can abort.
@MainActor
final class SilentOutput {
    /// Called when the system stopped the engine and restarting it failed.
    var onLost: (() -> Void)?

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    /// True between `start()` and `stop()`: a configuration change restarts the engine.
    private(set) var wantsRunning = false

    var isRunning: Bool { engine?.isRunning ?? false }

    func start(context: String) throws {
        wantsRunning = true
        let engine = self.engine ?? build()
        if engine.isRunning { return }
        let started = Date()
        engine.prepare()
        do {
            try engine.start()
            DiagLog.log("rec", "keepAlive start ok ms=\(EngineDiag.millis(since: started)) ctx=\(context)")
        } catch {
            DiagLog.log("rec", "keepAlive start failed \(EngineDiag.error(error)) ctx=\(context) app=\(EngineDiag.appState)")
            throw error
        }
    }

    func stop(context: String) {
        wantsRunning = false
        guard let engine, engine.isRunning else { return }
        engine.stop()
        DiagLog.log("rec", "keepAlive stop ctx=\(context)")
    }

    /// After a media-services reset every engine is invalid: drop it, the next start rebuilds.
    func discardEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine?.stop()
        engine = nil
    }

    private func build() -> AVAudioEngine {
        let engine = AVAudioEngine()
        let source = AVAudioSourceNode(renderBlock: Self.silenceBlock())
        engine.attach(source)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 1)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
        return engine
    }

    /// The route or category changed and the engine stopped itself. Restart it right away.
    private func handleConfigurationChange() {
        guard let engine, wantsRunning, !engine.isRunning else { return }
        DiagLog.log("rec", "keepAlive configuration change → restart \(EngineDiag.route())")
        do {
            try start(context: "configChange")
        } catch {
            onLost?()
        }
    }

    /// Built outside the main actor: it runs on the real-time render thread.
    nonisolated private static func silenceBlock() -> AVAudioSourceNodeRenderBlock {
        { _, _, _, bufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }
}
