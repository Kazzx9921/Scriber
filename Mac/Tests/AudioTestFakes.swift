import CoreAudio
import Foundation
import XCTest

/// Fakes for the audio session's ports. Nothing here touches Core Audio, the media service or a
/// sound: they record calls into a shared `EventLog` so tests can check the order.

final class EventLog {
    private(set) var items: [String] = []

    func add(_ item: String) { items.append(item) }

    func index(of item: String) -> Int? { items.firstIndex(of: item) }

    func clear() { items.removeAll() }
}

/// Isolated defaults per test, removed afterwards.
func makeTestDefaults(_ test: XCTestCase) -> UserDefaults {
    let name = "ScriberMacTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    test.addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return defaults
}

@MainActor
final class FakeScheduler: AudioScheduling {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private var items: [(at: Date, order: Int, timer: AudioTimer, work: @MainActor () -> Void)] = []
    private var counter = 0

    @discardableResult
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> AudioTimer {
        let timer = AudioTimer()
        counter += 1
        items.append((now.addingTimeInterval(max(0, seconds)), counter, timer, work))
        return timer
    }

    /// Moves the clock, running what falls due in order.
    func advance(_ seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = items.filter({ !$0.timer.isCancelled && $0.at <= target })
            .min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            items.removeAll { $0.order == next.order }
            now = max(now, next.at)
            next.work()
        }
        now = target
    }

    /// Wall-clock jump without running anything (the Mac slept; timers count awake time).
    func jumpClock(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }

    /// Runs everything still pending, whatever its time.
    func runAllPending() {
        while let next = items.filter({ !$0.timer.isCancelled }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            items.removeAll { $0.order == next.order }
            next.work()
        }
    }

    var pendingCount: Int { items.filter { !$0.timer.isCancelled }.count }
}

/// An output device world: devices with mute switches and/or volume controls per element.
final class FakeOutputPort: OutputAudioPort {
    struct Device {
        var uid: String
        var muteElements: [UInt32] = [0]
        var volumeElements: [UInt32] = [0]
        var muted: [UInt32: Bool] = [:]
        var volumes: [UInt32: Float] = [:]
        var connected = true
    }

    var devices: [AudioDeviceID: Device] = [:]
    var defaultID: AudioDeviceID?
    /// (device, element) pairs whose writes fail.
    var failingWrites: Set<String> = []
    var events: EventLog?
    /// Called before every write (to check what was persisted at that moment).
    var beforeWrite: (() -> Void)?
    private(set) var writes: [String] = []

    func addDevice(_ id: AudioDeviceID, _ device: Device, isDefault: Bool = false) {
        devices[id] = device
        if isDefault { defaultID = id }
    }

    func defaultOutput() -> (id: AudioDeviceID, uid: String)? {
        guard let id = defaultID, let device = devices[id], device.connected else { return nil }
        return (id, device.uid)
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        devices.first { $0.value.uid == uid && $0.value.connected }?.key
    }

    func settableMuteElements(_ device: AudioDeviceID) -> [UInt32] { devices[device]?.muteElements ?? [] }
    func settableVolumeElements(_ device: AudioDeviceID) -> [UInt32] { devices[device]?.volumeElements ?? [] }

    func isMuted(_ device: AudioDeviceID, element: UInt32) -> Bool? {
        guard let entry = devices[device], entry.muteElements.contains(element) else { return nil }
        return entry.muted[element] ?? false
    }

    func setMuted(_ device: AudioDeviceID, element: UInt32, _ muted: Bool) -> OSStatus {
        beforeWrite?()
        writes.append("mute \(device)/\(element)=\(muted)")
        guard !failingWrites.contains("\(device)/\(element)") else { return kAudioHardwareUnspecifiedError }
        devices[device]?.muted[element] = muted
        events?.add(muted ? "mute" : "unmute")
        return noErr
    }

    func volume(_ device: AudioDeviceID, element: UInt32) -> Float? {
        guard let entry = devices[device], entry.volumeElements.contains(element) else { return nil }
        return entry.volumes[element] ?? 1
    }

    func setVolume(_ device: AudioDeviceID, element: UInt32, _ volume: Float) -> OSStatus {
        beforeWrite?()
        writes.append("volume \(device)/\(element)=\(volume)")
        guard !failingWrites.contains("\(device)/\(element)") else { return kAudioHardwareUnspecifiedError }
        devices[device]?.volumes[element] = volume
        events?.add(volume == 0 ? "mute" : "unmute")
        return noErr
    }
}

@MainActor
final class FakeMediaPort: MediaControlPort {
    var pauseResult: MediaPauseResult = .notPlaying
    var resumeResult: MediaResumeResult = .resumed
    /// Hold the pause result until `completePause()`.
    var deferPause = false
    var events: EventLog?
    private(set) var pauseRequests = 0
    private(set) var resumes: [NowPlayingApp] = []
    private(set) var detachedResumes: [NowPlayingApp] = []
    private var pending: (@MainActor (MediaPauseResult) -> Void)?

    func probe(_ completion: @escaping @MainActor (MediaAvailability) -> Void) {
        completion(.available)
    }

    func pauseIfPlaying(_ completion: @escaping @MainActor (MediaPauseResult) -> Void) {
        pauseRequests += 1
        events?.add("media.pause")
        if deferPause {
            pending = completion
        } else {
            completion(pauseResult)
        }
    }

    func completePause() {
        let completion = pending
        pending = nil
        completion?(pauseResult)
    }

    func resume(_ app: NowPlayingApp, _ completion: @escaping @MainActor (MediaResumeResult) -> Void) {
        resumes.append(app)
        events?.add("media.resume")
        completion(resumeResult)
    }

    func resumeDetached(_ app: NowPlayingApp) {
        detachedResumes.append(app)
        events?.add("media.resumeNow")
    }
}

@MainActor
final class FakeCuePort: CuePort {
    var durations: [CueKind: TimeInterval] = [.start: 0.42, .stop: 0.43]
    var events: EventLog?
    private(set) var played: [CueKind] = []

    func play(_ kind: CueKind, prefs: AudioPreferences) -> TimeInterval? {
        guard prefs.cue(kind).effectiveSource != .none else { return nil }
        played.append(kind)
        events?.add("cue.\(kind.rawValue)")
        return durations[kind]
    }
}
