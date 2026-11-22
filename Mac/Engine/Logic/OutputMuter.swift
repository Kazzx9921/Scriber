import CoreAudio
import Foundation
import ScriberShared

/// What the muter needs from Core Audio. The app uses `CoreAudioOutputPort`; tests use a fake.
/// Elements: 0 is the device's main control, 1… its channels.
protocol OutputAudioPort: AnyObject {
    /// The current default output device (id, UID, name for nothing but the menu).
    func defaultOutput() -> (id: AudioDeviceID, uid: String)?
    func deviceID(forUID uid: String) -> AudioDeviceID?
    /// Elements whose mute switch can be set.
    func settableMuteElements(_ device: AudioDeviceID) -> [UInt32]
    /// Elements whose volume can be set.
    func settableVolumeElements(_ device: AudioDeviceID) -> [UInt32]
    func isMuted(_ device: AudioDeviceID, element: UInt32) -> Bool?
    func setMuted(_ device: AudioDeviceID, element: UInt32, _ muted: Bool) -> OSStatus
    func volume(_ device: AudioDeviceID, element: UInt32) -> Float?
    func setVolume(_ device: AudioDeviceID, element: UInt32, _ volume: Float) -> OSStatus
}

/// What Scriber changed on one output device, persisted before the change is made so a relaunch
/// after a crash can undo it.
struct MuteRecord: Codable, Equatable, Sendable {
    enum Method: String, Codable, Sendable {
        /// The device's mute switch(es) were turned on.
        case mute
        /// No mute switch: the volume was set to 0; `volumes` holds the values before.
        case volume
    }

    var uid: String
    var method: Method
    var elements: [UInt32]
    /// `.volume` only, parallel to `elements`.
    var volumes: [Float]
    var date: Date
}

/// Mutes the default output for the length of a recording and puts it back.
///
/// Rules (all unit-tested):
/// - Only a device that is audible gets touched; an already muted (or silent) device is left alone
///   and is not "restored" afterwards.
/// - Before changing anything the record is written to the defaults; it is removed only once the
///   device is back to how it was. `recoverAtLaunch()` undoes a record left by a crash or a kill.
/// - Restore goes to the device that was muted (by UID), whatever the default output is by then.
/// - Restore only undoes what is still in the state Scriber left it: if the user unmuted or turned
///   the volume up meanwhile, their choice stays.
/// - A device that is gone keeps its record; `restorePending` runs again at the next recording, on
///   device changes and at launch.
@MainActor
final class OutputMuter {
    enum MuteOutcome: Equatable {
        case muted(MuteRecord)
        /// Muted or at zero volume already: nothing to do, nothing to restore.
        case alreadySilent
        /// The device has neither a settable mute nor a settable volume (some HDMI and USB outputs).
        case unsupported
        case noOutputDevice
        case failed(OSStatus)
    }

    enum RestoreOutcome: Equatable {
        case restored
        /// Already unmuted / volume changed by the user: left as it is.
        case userChanged
        /// Not connected: the record is kept for later.
        case deviceGone
        /// Writing failed: the record is kept for another try.
        case failed(OSStatus)
    }

    static let defaultsKey = "mac.audio.mutedOutput"
    /// A volume at or below this counts as "still at the 0 Scriber set".
    static let silentVolume: Float = 0.001

    private let port: OutputAudioPort
    private let defaults: UserDefaults
    private let log: (String) -> Void

    init(port: OutputAudioPort, defaults: UserDefaults, log: @escaping (String) -> Void = { DiagLog.log("audio", $0) }) {
        self.port = port
        self.defaults = defaults
        self.log = log
    }

    /// Records not yet undone (normally empty between recordings).
    var pendingRecords: [MuteRecord] { load() }

    // MARK: Mute

    func muteDefaultOutput() -> MuteOutcome {
        guard let output = port.defaultOutput() else {
            log("mute skipped: no output device")
            return .noOutputDevice
        }
        let tag = AudioLog.tag(output.uid)
        if load().contains(where: { $0.uid == output.uid }) {
            // A restore that failed earlier still owns this device; it is silent because of us.
            log("mute skipped \(tag): still muted from an earlier recording")
            return .alreadySilent
        }

        let muteElements = port.settableMuteElements(output.id)
        if !muteElements.isEmpty {
            let audible = muteElements.filter { port.isMuted(output.id, element: $0) == false }
            guard !audible.isEmpty else {
                log("mute skipped \(tag): already muted")
                return .alreadySilent
            }
            let record = MuteRecord(uid: output.uid, method: .mute, elements: audible, volumes: [], date: Date())
            save(load() + [record])
            for element in audible {
                let status = port.setMuted(output.id, element: element, true)
                guard status == noErr else {
                    log("mute failed \(tag) element=\(element) status=\(AudioLog.status(status)) → undoing")
                    undo(record, upTo: element, device: output.id)
                    return .failed(status)
                }
            }
            log("muted \(tag) method=mute elements=\(audible) status=0")
            return .muted(record)
        }

        let volumeElements = port.settableVolumeElements(output.id)
        guard !volumeElements.isEmpty else {
            log("mute unsupported \(tag): no settable mute or volume")
            return .unsupported
        }
        let levels = volumeElements.map { (element: $0, volume: port.volume(output.id, element: $0)) }
        let audible = levels.compactMap { item -> (UInt32, Float)? in
            guard let volume = item.volume, volume > Self.silentVolume else { return nil }
            return (item.element, volume)
        }
        guard !audible.isEmpty else {
            log("mute skipped \(tag): volume already 0")
            return .alreadySilent
        }
        let record = MuteRecord(uid: output.uid, method: .volume, elements: audible.map(\.0), volumes: audible.map(\.1),
                                date: Date())
        save(load() + [record])
        for (element, _) in audible {
            let status = port.setVolume(output.id, element: element, 0)
            guard status == noErr else {
                log("mute failed \(tag) method=volume element=\(element) status=\(AudioLog.status(status)) → undoing")
                undo(record, upTo: element, device: output.id)
                return .failed(status)
            }
        }
        log("muted \(tag) method=volume elements=\(record.elements) status=0")
        return .muted(record)
    }

    /// A mute that failed halfway: put back the elements already changed, drop the record.
    private func undo(_ record: MuteRecord, upTo failed: UInt32, device: AudioDeviceID) {
        for (index, element) in record.elements.enumerated() {
            guard element != failed else { break }
            switch record.method {
            case .mute: _ = port.setMuted(device, element: element, false)
            case .volume: _ = port.setVolume(device, element: element, record.volumes[index])
            }
        }
        save(load().filter { $0 != record })
    }

    // MARK: Restore

    /// Undoes every record (normally the one from this recording). Returns one outcome per record.
    @discardableResult
    func restorePending(reason: String) -> [RestoreOutcome] {
        let records = load()
        guard !records.isEmpty else { return [] }
        var kept: [MuteRecord] = []
        var outcomes: [RestoreOutcome] = []
        for record in records {
            let outcome = restore(record)
            outcomes.append(outcome)
            let tag = AudioLog.tag(record.uid)
            switch outcome {
            case .restored:
                log("unmuted \(tag) method=\(record.method.rawValue) reason=\(reason) status=0")
            case .userChanged:
                log("unmute not needed \(tag) reason=\(reason): changed by the user meanwhile")
            case .deviceGone:
                kept.append(record)
                log("unmute pending \(tag) reason=\(reason): device not connected, will retry")
            case .failed(let status):
                kept.append(record)
                log("unmute failed \(tag) reason=\(reason) status=\(AudioLog.status(status)), will retry")
            }
        }
        save(kept)
        return outcomes
    }

    private func restore(_ record: MuteRecord) -> RestoreOutcome {
        guard let device = port.deviceID(forUID: record.uid) else { return .deviceGone }
        var changedSomething = false
        for (index, element) in record.elements.enumerated() {
            switch record.method {
            case .mute:
                guard port.isMuted(device, element: element) == true else { continue }
                let status = port.setMuted(device, element: element, false)
                guard status == noErr else { return .failed(status) }
                changedSomething = true
            case .volume:
                guard let current = port.volume(device, element: element), current <= Self.silentVolume else { continue }
                let status = port.setVolume(device, element: element, record.volumes[index])
                guard status == noErr else { return .failed(status) }
                changedSomething = true
            }
        }
        return changedSomething ? .restored : .userChanged
    }

    /// At launch: a record still here means the app ended while muted (crash, kill, power loss).
    func recoverAtLaunch() {
        let records = load()
        guard !records.isEmpty else { return }
        log("launch: \(records.count) output(s) still muted by a previous run → restoring")
        restorePending(reason: "launch-recovery")
    }

    // MARK: Storage

    private func load() -> [MuteRecord] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([MuteRecord].self, from: data)) ?? []
    }

    private func save(_ records: [MuteRecord]) {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        // The record must reach the preferences daemon before the device is muted: a crash right
        // after must still find it at the next launch.
        defaults.synchronize()
    }
}
