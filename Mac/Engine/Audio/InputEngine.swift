import AudioToolbox
import AVFoundation
import CoreAudio
import ScriberShared

/// Builds and starts a fresh `AVAudioEngine` input for the recorder and the settings' 測試, on the
/// pinned microphone when it is connected and usable, else on the system default.
///
/// The pinned device is set on the input node's audio unit (`kAudioOutputUnitProperty_CurrentDevice`)
/// before anything reads the node's format, installs the tap or prepares the engine; nothing else
/// in the engine is touched (no output node), so only the input moves. The system default input
/// is never changed. Every way the pinned device can fail — the audio unit refuses it, it reports
/// no channels or mismatched formats, the engine will not start on it, or the unit ends up on
/// another device — falls back to the system default for this start, with the reason in the log.
///
/// The tap is installed with `format: nil` (the node's own output format), so a device whose
/// format differs from what the engine expected can never raise the "format mismatch" exception.
enum InputEngine {
    struct Started {
        let engine: AVAudioEngine
        let route: InputRoute
        /// "48000Hz/1ch".
        let description: String
    }

    enum Failure: Error {
        case noInputDevice(String)
        case engine(Error)
        case pin(OSStatus)
    }

    /// Main thread. `tap` runs on the audio thread.
    static func start(pinnedUID: String?, tag: String, tap: @escaping (AVAudioPCMBuffer) -> Void) throws -> Started {
        var route = InputDeviceResolver.resolve(pinnedUID: pinnedUID, devices: pinnedUID == nil ? [] : CoreAudioQuery.inputDevices())
        if case .pinned(let device) = route {
            do {
                return try start(device: device, route: route, tap: tap)
            } catch {
                DiagLog.log("rec", "\(tag) pinned input \(device.logDescription) unusable \(describe(error)) → system default")
                route = .systemDefault(.pinnedFailed)
            }
        }
        return try start(device: nil, route: route, tap: tap)
    }

    private static func start(device: AudioInputDevice?, route: InputRoute,
                              tap: @escaping (AVAudioPCMBuffer) -> Void) throws -> Started {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device {
            guard let unit = input.audioUnit else { throw Failure.pin(-1) }
            var id = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw Failure.pin(status) }
        }
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        let description = "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
        // No input device (or one with no input channels): installing a tap would raise.
        guard format.sampleRate > 0, format.channelCount > 0, hardware.channelCount > 0 else {
            throw Failure.noInputDevice(description)
        }
        if device != nil, hardware.sampleRate > 0, abs(hardware.sampleRate - format.sampleRate) > 0.5 {
            throw Failure.noInputDevice("\(description) hw=\(Int(hardware.sampleRate))Hz")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in tap(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engine(error)
        }
        if let device, let unit = input.audioUnit {
            var current = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &current, &size)
            if status == noErr, current != device.id {
                input.removeTap(onBus: 0)
                engine.stop()
                throw Failure.pin(kAudioHardwareBadDeviceError)
            }
        }
        return Started(engine: engine, route: route, description: description)
    }

    static func describe(_ error: Error) -> String {
        switch error as? Failure {
        case .noInputDevice(let format)?: "no-input(\(format))"
        case .engine(let underlying)?: "engine(\(MacDiag.error(underlying)))"
        case .pin(let status)?: "pin(\(AudioLog.status(status)))"
        case nil: MacDiag.error(error)
        }
    }
}
