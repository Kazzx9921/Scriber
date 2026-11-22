import CoreAudio
import Foundation

/// The real `OutputAudioPort`: reads and sets the mute switch / volume of an output device.
/// Only `OutputMuter` calls the setters, and only while a recording runs (or to undo that).
final class CoreAudioOutputPort: OutputAudioPort {
    private let scope = kAudioObjectPropertyScopeOutput

    func defaultOutput() -> (id: AudioDeviceID, uid: String)? {
        guard let id = CoreAudioQuery.defaultOutputDeviceID(), let uid = CoreAudioQuery.uid(id) else { return nil }
        return (id, uid)
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard let id = CoreAudioQuery.deviceID(forUID: uid), CoreAudioQuery.isAlive(id) else { return nil }
        return id
    }

    func settableMuteElements(_ device: AudioDeviceID) -> [UInt32] {
        settableElements(device, selector: kAudioDevicePropertyMute)
    }

    func settableVolumeElements(_ device: AudioDeviceID) -> [UInt32] {
        settableElements(device, selector: kAudioDevicePropertyVolumeScalar)
    }

    /// The main element if it has the control, else each channel that has it.
    private func settableElements(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> [UInt32] {
        if isSettable(device, selector: selector, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        let channels = CoreAudioQuery.channelCount(device, scope: scope)
        guard channels > 0 else { return [] }
        return (1...UInt32(min(channels, 64))).filter { isSettable(device, selector: selector, element: $0) }
    }

    private func isSettable(_ device: AudioDeviceID, selector: AudioObjectPropertySelector, element: UInt32) -> Bool {
        var address = CoreAudioQuery.address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func isMuted(_ device: AudioDeviceID, element: UInt32) -> Bool? {
        CoreAudioQuery.uint32(device, CoreAudioQuery.address(kAudioDevicePropertyMute, scope: scope, element: element)).map { $0 != 0 }
    }

    func setMuted(_ device: AudioDeviceID, element: UInt32, _ muted: Bool) -> OSStatus {
        var address = CoreAudioQuery.address(kAudioDevicePropertyMute, scope: scope, element: element)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    func volume(_ device: AudioDeviceID, element: UInt32) -> Float? {
        CoreAudioQuery.float32(device, CoreAudioQuery.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element))
    }

    func setVolume(_ device: AudioDeviceID, element: UInt32, _ volume: Float) -> OSStatus {
        var address = CoreAudioQuery.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
        var value = Float32(min(max(volume, 0), 1))
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
