import CoreAudio
import Foundation
import ScriberShared

extension Notification.Name {
    /// Posted on the main queue (coalesced) when devices appear or disappear, or the default input
    /// or output changes.
    static let scriberAudioDevicesChanged = Notification.Name("ScriberAudioDevicesChanged")
}

/// Core Audio property listeners on the system object: the device list and the default input and
/// output. Listening opens no device and costs nothing while nothing changes. Started once
/// (`start()` is idempotent) and kept for the life of the app.
@MainActor
final class AudioDeviceMonitor {
    static let shared = AudioDeviceMonitor()

    private var started = false
    private var pending: DispatchWorkItem?
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func start() {
        guard !started else { return }
        started = true
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice]
        for selector in selectors {
            var address = CoreAudioQuery.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed() }
            }
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            if status == noErr {
                registrations.append((address, block))
            } else {
                DiagLog.log("audio", "device listener failed selector=\(AudioLog.status(Int32(bitPattern: selector))) "
                            + "status=\(AudioLog.status(status))")
            }
        }
    }

    /// Bursts (a Bluetooth headset adds input and output, then becomes default) become one post.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .scriberAudioDevicesChanged, object: nil)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
