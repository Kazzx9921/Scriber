import CoreAudio
import XCTest

final class AudioDevicesTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 10, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro的麥克風",
                                           transport: .builtIn, inputChannels: 1)
    private let yeti = AudioInputDevice(id: 12, uid: "yeti", name: "Yeti", transport: .usb, inputChannels: 2)

    // MARK: Choosing the input

    func testFollowSystemUsesDefault() {
        XCTAssertEqual(InputDeviceResolver.resolve(pinnedUID: nil, devices: [builtIn, yeti]), .systemDefault(.followSystem))
    }

    func testPinnedAndConnectedIsUsed() {
        XCTAssertEqual(InputDeviceResolver.resolve(pinnedUID: "yeti", devices: [builtIn, yeti]), .pinned(yeti))
    }

    func testPinnedButUnpluggedFallsBackToDefault() {
        let route = InputDeviceResolver.resolve(pinnedUID: "yeti", devices: [builtIn])
        XCTAssertEqual(route, .systemDefault(.pinnedMissing))
        XCTAssertTrue(route.isFallback)
    }

    func testPinnedWithoutInputChannelsFallsBack() {
        var silent = yeti
        silent.inputChannels = 0
        XCTAssertEqual(InputDeviceResolver.resolve(pinnedUID: "yeti", devices: [builtIn, silent]), .systemDefault(.pinnedFailed))
    }

    func testFollowSystemIsNotAFallback() {
        XCTAssertFalse(InputRoute.systemDefault(.followSystem).isFallback)
        XCTAssertFalse(InputRoute.pinned(yeti).isFallback)
        XCTAssertTrue(InputRoute.systemDefault(.pinnedFailed).isFallback)
    }

    // MARK: Telling the user once

    func testFallbackIsAnnouncedOncePerAbsence() {
        var notice = MicFallbackNotice()
        let missing = InputRoute.systemDefault(.pinnedMissing)
        XCTAssertTrue(notice.shouldNotify(pinnedUID: "yeti", route: missing), "first recording without it")
        XCTAssertFalse(notice.shouldNotify(pinnedUID: "yeti", route: missing), "not again while it stays away")
        XCTAssertFalse(notice.shouldNotify(pinnedUID: "yeti", route: missing))
        XCTAssertFalse(notice.shouldNotify(pinnedUID: "yeti", route: .pinned(yeti)), "it is back")
        XCTAssertTrue(notice.shouldNotify(pinnedUID: "yeti", route: missing), "gone again: tell again")
    }

    func testChangingThePinnedDeviceAnnouncesAgain() {
        var notice = MicFallbackNotice()
        XCTAssertTrue(notice.shouldNotify(pinnedUID: "yeti", route: .systemDefault(.pinnedMissing)))
        XCTAssertTrue(notice.shouldNotify(pinnedUID: "airpods", route: .systemDefault(.pinnedMissing)))
        XCTAssertFalse(notice.shouldNotify(pinnedUID: nil, route: .systemDefault(.followSystem)))
        XCTAssertTrue(notice.shouldNotify(pinnedUID: "airpods", route: .systemDefault(.pinnedFailed)))
    }

    func testHUDLabelFitsThePill() {
        XCTAssertLessThanOrEqual(MicFallbackNotice.hudLabel.count, 8)
    }

    // MARK: Output kind (start cue reaching the microphone)

    func testOutputKind() {
        XCTAssertEqual(OutputKind.classify(transport: .builtIn, dataSource: OutputKind.DataSource.internalSpeaker), .speaker)
        XCTAssertEqual(OutputKind.classify(transport: .builtIn, dataSource: nil), .speaker)
        XCTAssertEqual(OutputKind.classify(transport: .builtIn, dataSource: OutputKind.DataSource.headphones), .headphones)
        XCTAssertEqual(OutputKind.classify(transport: .hdmi, dataSource: nil), .speaker)
        XCTAssertEqual(OutputKind.classify(transport: .airPlay, dataSource: nil), .speaker)
        XCTAssertEqual(OutputKind.classify(transport: .bluetooth, dataSource: nil), .unknown)
        XCTAssertEqual(OutputKind.classify(transport: .usb, dataSource: nil), .unknown)
    }

    func testTransportMapping() {
        XCTAssertEqual(AudioTransport(rawValue: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(AudioTransport(rawValue: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(AudioTransport(rawValue: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(AudioTransport(rawValue: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(AudioTransport(rawValue: kAudioDeviceTransportTypeContinuityCaptureWireless), .continuity)
        XCTAssertEqual(AudioTransport(rawValue: 0), .other)
        XCTAssertEqual(builtIn.menuTitle, "MacBook Pro的麥克風・內建")
        XCTAssertEqual(AudioInputDevice(id: 1, uid: "u", name: "X", transport: .other, inputChannels: 1).menuTitle, "X")
    }

    func testPlumbingIsHidden() {
        XCTAssertTrue(CoreAudioQuery.isPlumbing(uid: "CADefaultDeviceAggregate-1234-5", hidden: false))
        XCTAssertTrue(CoreAudioQuery.isPlumbing(uid: "anything", hidden: true))
        XCTAssertFalse(CoreAudioQuery.isPlumbing(uid: "BlackHole2ch_UID", hidden: false))
    }

    // MARK: Read-only Core Audio (this Mac; nothing is opened or changed)

    func testListingThisMacsInputs() {
        let devices = CoreAudioQuery.inputDevices()
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count, "UIDs are unique")
        for device in devices {
            XCTAssertGreaterThan(device.inputChannels, 0)
            XCTAssertFalse(device.uid.hasPrefix("CADefaultDeviceAggregate"))
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertEqual(CoreAudioQuery.deviceID(forUID: device.uid), device.id)
        }
        if let first = devices.first, devices.contains(where: { $0.transport == .builtIn }) {
            XCTAssertEqual(first.transport, .builtIn, "built-in first")
        }
        if let defaultID = CoreAudioQuery.defaultInputDeviceID() {
            XCTAssertTrue(devices.contains { $0.id == defaultID } || devices.isEmpty,
                          "the default input is in the list")
        }
        _ = CoreAudioQuery.defaultOutputKind()
        XCTAssertNil(CoreAudioQuery.deviceID(forUID: "no-such-device-\(UUID().uuidString)"))
    }
}
