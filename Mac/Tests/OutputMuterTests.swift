import CoreAudio
import XCTest

/// Muting the output while recording, and every way it is undone. Fake Core Audio only.
@MainActor
final class OutputMuterTests: XCTestCase {
    private func world(_ device: FakeOutputPort.Device = .init(uid: "speakers")) -> (FakeOutputPort, UserDefaults) {
        let port = FakeOutputPort()
        port.addDevice(1, device, isDefault: true)
        return (port, makeTestDefaults(self))
    }

    private func muter(_ port: FakeOutputPort, _ defaults: UserDefaults) -> OutputMuter {
        OutputMuter(port: port, defaults: defaults, log: { _ in })
    }

    // MARK: Mute switch

    func testMutesAndRestoresWithTheMuteSwitch() {
        let (port, defaults) = world()
        let muter = muter(port, defaults)
        guard case .muted(let record) = muter.muteDefaultOutput() else { return XCTFail("not muted") }
        XCTAssertEqual(record.method, .mute)
        XCTAssertEqual(port.devices[1]?.muted[0], true)
        XCTAssertEqual(muter.pendingRecords.count, 1)

        XCTAssertEqual(muter.restorePending(reason: "finished"), [.restored])
        XCTAssertEqual(port.devices[1]?.muted[0], false)
        XCTAssertTrue(muter.pendingRecords.isEmpty)
        XCTAssertNil(defaults.data(forKey: OutputMuter.defaultsKey))
    }

    /// The crash-recovery record must exist before the device is changed.
    func testRecordIsPersistedBeforeTheDeviceIsTouched() {
        let (port, defaults) = world()
        let muter = muter(port, defaults)
        var persistedAtFirstWrite: Bool?
        port.beforeWrite = {
            if persistedAtFirstWrite == nil { persistedAtFirstWrite = defaults.data(forKey: OutputMuter.defaultsKey) != nil }
        }
        _ = muter.muteDefaultOutput()
        XCTAssertEqual(persistedAtFirstWrite, true)
    }

    func testAlreadyMutedIsLeftAloneAndNotUnmutedLater() {
        var device = FakeOutputPort.Device(uid: "speakers")
        device.muted[0] = true
        let (port, defaults) = world(device)
        let muter = muter(port, defaults)
        XCTAssertEqual(muter.muteDefaultOutput(), .alreadySilent)
        XCTAssertTrue(muter.restorePending(reason: "finished").isEmpty)
        XCTAssertEqual(port.devices[1]?.muted[0], true, "the user's own mute stays")
        XCTAssertTrue(port.writes.isEmpty)
    }

    func testUserUnmutedDuringRecordingIsRespected() {
        let (port, defaults) = world()
        let muter = muter(port, defaults)
        _ = muter.muteDefaultOutput()
        port.devices[1]?.muted[0] = false // the user pressed the mute key
        let writesBefore = port.writes.count
        XCTAssertEqual(muter.restorePending(reason: "finished"), [.userChanged])
        XCTAssertEqual(port.writes.count, writesBefore, "nothing written")
        XCTAssertTrue(muter.pendingRecords.isEmpty)
    }

    func testPerChannelMuteWhenThereIsNoMainElement() {
        let (port, defaults) = world(.init(uid: "usb", muteElements: [1, 2], volumeElements: []))
        let muter = muter(port, defaults)
        guard case .muted(let record) = muter.muteDefaultOutput() else { return XCTFail("not muted") }
        XCTAssertEqual(record.elements, [1, 2])
        XCTAssertEqual(port.devices[1]?.muted, [1: true, 2: true])
        muter.restorePending(reason: "finished")
        XCTAssertEqual(port.devices[1]?.muted, [1: false, 2: false])
    }

    func testHalfFailedMuteIsUndone() {
        let (port, defaults) = world(.init(uid: "usb", muteElements: [1, 2], volumeElements: []))
        port.failingWrites = ["1/2"]
        let muter = muter(port, defaults)
        XCTAssertEqual(muter.muteDefaultOutput(), .failed(kAudioHardwareUnspecifiedError))
        XCTAssertEqual(port.devices[1]?.muted[1], false, "channel 1 put back")
        XCTAssertTrue(muter.pendingRecords.isEmpty)
    }

    // MARK: Volume fallback

    func testDeviceWithoutMuteUsesVolumeAndPutsItBack() {
        var device = FakeOutputPort.Device(uid: "hdmi", muteElements: [], volumeElements: [1, 2])
        device.volumes = [1: 0.7, 2: 0.5]
        let (port, defaults) = world(device)
        let muter = muter(port, defaults)
        guard case .muted(let record) = muter.muteDefaultOutput() else { return XCTFail("not muted") }
        XCTAssertEqual(record.method, .volume)
        XCTAssertEqual(port.devices[1]?.volumes, [1: 0, 2: 0])
        muter.restorePending(reason: "finished")
        XCTAssertEqual(port.devices[1]?.volumes, [1: 0.7, 2: 0.5])
    }

    func testVolumeRaisedByTheUserIsNotOverwritten() {
        var device = FakeOutputPort.Device(uid: "hdmi", muteElements: [], volumeElements: [0])
        device.volumes = [0: 0.8]
        let (port, defaults) = world(device)
        let muter = muter(port, defaults)
        _ = muter.muteDefaultOutput()
        port.devices[1]?.volumes[0] = 0.3
        XCTAssertEqual(muter.restorePending(reason: "finished"), [.userChanged])
        XCTAssertEqual(port.devices[1]?.volumes[0], 0.3)
    }

    func testSilentVolumeIsLeftAlone() {
        var device = FakeOutputPort.Device(uid: "hdmi", muteElements: [], volumeElements: [0])
        device.volumes = [0: 0]
        let (port, defaults) = world(device)
        XCTAssertEqual(muter(port, defaults).muteDefaultOutput(), .alreadySilent)
    }

    func testNoControlsAtAll() {
        let (port, defaults) = world(.init(uid: "dumb", muteElements: [], volumeElements: []))
        let muter = muter(port, defaults)
        XCTAssertEqual(muter.muteDefaultOutput(), .unsupported)
        XCTAssertTrue(muter.pendingRecords.isEmpty)
    }

    func testNoOutputDevice() {
        let port = FakeOutputPort()
        XCTAssertEqual(muter(port, makeTestDefaults(self)).muteDefaultOutput(), .noOutputDevice)
    }

    // MARK: Device changes

    /// Headphones plugged in mid-recording: the speakers that were muted get unmuted, the new
    /// default is not touched.
    func testRestoresTheDeviceThatWasMutedNotTheNewDefault() {
        let (port, defaults) = world()
        port.addDevice(2, .init(uid: "headphones"))
        let muter = muter(port, defaults)
        _ = muter.muteDefaultOutput()
        port.defaultID = 2
        muter.restorePending(reason: "finished")
        XCTAssertEqual(port.devices[1]?.muted[0], false)
        XCTAssertNil(port.devices[2]?.muted[0])
        XCTAssertFalse(port.writes.contains { $0.hasPrefix("mute 2/") })
    }

    func testDeviceGoneKeepsTheRecordUntilItReturns() {
        let (port, defaults) = world(.init(uid: "bt-speaker"))
        let muter = muter(port, defaults)
        _ = muter.muteDefaultOutput()
        port.devices[1]?.connected = false
        XCTAssertEqual(muter.restorePending(reason: "finished"), [.deviceGone])
        XCTAssertEqual(muter.pendingRecords.count, 1)

        port.devices[1]?.connected = true
        XCTAssertEqual(muter.restorePending(reason: "device-change"), [.restored])
        XCTAssertEqual(port.devices[1]?.muted[0], false)
        XCTAssertTrue(muter.pendingRecords.isEmpty)
    }

    func testFailedUnmuteIsRetried() {
        let (port, defaults) = world()
        let muter = muter(port, defaults)
        _ = muter.muteDefaultOutput()
        port.failingWrites = ["1/0"]
        XCTAssertEqual(muter.restorePending(reason: "finished"), [.failed(kAudioHardwareUnspecifiedError)])
        XCTAssertEqual(muter.pendingRecords.count, 1)
        port.failingWrites = []
        XCTAssertEqual(muter.restorePending(reason: "retry"), [.restored])
        XCTAssertEqual(port.devices[1]?.muted[0], false)
    }

    func testDeviceStillOwnedByAPendingRecordIsNotRecordedTwice() {
        let (port, defaults) = world()
        let muter = muter(port, defaults)
        _ = muter.muteDefaultOutput()
        port.failingWrites = ["1/0"]
        muter.restorePending(reason: "finished") // fails: still muted by us
        port.failingWrites = []
        XCTAssertEqual(muter.muteDefaultOutput(), .alreadySilent)
        XCTAssertEqual(muter.pendingRecords.count, 1, "the original record (previous state: unmuted) is kept")
        muter.restorePending(reason: "finished")
        XCTAssertEqual(port.devices[1]?.muted[0], false)
    }

    // MARK: Crash recovery

    func testRelaunchAfterACrashUnmutes() {
        let (port, defaults) = world()
        _ = muter(port, defaults).muteDefaultOutput()
        // The process dies here. A new launch reads the record from the defaults.
        let relaunched = muter(port, defaults)
        relaunched.recoverAtLaunch()
        XCTAssertEqual(port.devices[1]?.muted[0], false)
        XCTAssertTrue(relaunched.pendingRecords.isEmpty)
    }

    func testRelaunchWithNothingToRecoverWritesNothing() {
        let (port, defaults) = world()
        muter(port, defaults).recoverAtLaunch()
        XCTAssertTrue(port.writes.isEmpty)
    }

    func testCorruptRecordIsIgnored() {
        let (port, defaults) = world()
        defaults.set(Data("not json".utf8), forKey: OutputMuter.defaultsKey)
        let muter = muter(port, defaults)
        muter.recoverAtLaunch()
        XCTAssertTrue(port.writes.isEmpty)
        XCTAssertTrue(muter.pendingRecords.isEmpty)
    }
}
