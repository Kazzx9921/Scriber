import CoreAudio
import Foundation

/// How a device is connected, from `kAudioDevicePropertyTransportType`.
enum AudioTransport: Equatable, Sendable {
    case builtIn, bluetooth, usb, continuity, virtual, aggregate, hdmi, displayPort, airPlay, thunderbolt, other

    init(rawValue: UInt32) {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuity
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        default: self = .other
        }
    }

    /// A few words after the device name in the menu.
    var label: String? {
        switch self {
        case .builtIn: "內建"
        case .bluetooth: "藍牙"
        case .usb: "USB"
        case .continuity: "iPhone"
        case .virtual: "虛擬"
        case .aggregate: "聚集"
        case .hdmi: "HDMI"
        case .displayPort: "DisplayPort"
        case .airPlay: "AirPlay"
        case .thunderbolt: "Thunderbolt"
        case .other: nil
        }
    }

    var logName: String { String(describing: self) }
}

/// A device with input channels.
struct AudioInputDevice: Identifiable, Equatable, Sendable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var transport: AudioTransport
    var inputChannels: Int

    var menuTitle: String {
        transport.label.map { "\(name)・\($0)" } ?? name
    }

    var logDescription: String {
        "\(AudioLog.tag(uid)) \(transport.logName) \(inputChannels)ch"
    }
}

/// Where the default output plays, as far as it matters for the start cue reaching the microphone.
enum OutputKind: String, Equatable, Sendable {
    /// Built-in speakers, a display or TV, AirPlay: the cue is heard by the microphone.
    case speaker
    /// Headphones on the built-in jack.
    case headphones
    /// Bluetooth, USB and the rest: could be either.
    case unknown

    /// `dataSource` is the built-in output's `kAudioDevicePropertyDataSource` ('ispk' / 'hdpn').
    static func classify(transport: AudioTransport, dataSource: UInt32?) -> OutputKind {
        switch transport {
        case .builtIn:
            if dataSource == DataSource.headphones { return .headphones }
            return .speaker
        case .hdmi, .displayPort, .airPlay:
            return .speaker
        default:
            return .unknown
        }
    }

    enum DataSource {
        static let internalSpeaker: UInt32 = 0x6973_706B // 'ispk'
        static let headphones: UInt32 = 0x6864_706E // 'hdpn'
    }
}

// MARK: - Choosing the input for a recording

/// Which input a recording uses and why.
enum InputRoute: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        /// 跟隨系統.
        case followSystem = "follow-system"
        /// The pinned device is not connected.
        case pinnedMissing = "pinned-missing"
        /// The pinned device is connected but could not be used (no input channels, the audio unit
        /// refused it, the engine would not start on it).
        case pinnedFailed = "pinned-failed"
    }

    case systemDefault(Reason)
    case pinned(AudioInputDevice)

    var isFallback: Bool {
        if case .systemDefault(let reason) = self { return reason != .followSystem }
        return false
    }

    var logDescription: String {
        switch self {
        case .systemDefault(let reason): "default(\(reason.rawValue))"
        case .pinned(let device): "pinned(\(device.logDescription))"
        }
    }
}

enum InputDeviceResolver {
    /// The pinned device if it is connected and has input channels, else the system default.
    static func resolve(pinnedUID: String?, devices: [AudioInputDevice]) -> InputRoute {
        guard let pinnedUID else { return .systemDefault(.followSystem) }
        guard let device = devices.first(where: { $0.uid == pinnedUID }) else { return .systemDefault(.pinnedMissing) }
        guard device.inputChannels > 0 else { return .systemDefault(.pinnedFailed) }
        return .pinned(device)
    }
}

/// "改用預設麥克風" once per absence of the pinned device: the first recording that falls back tells
/// the user; the following ones do not, until the device has been used again (or the choice changed).
struct MicFallbackNotice: Equatable {
    private(set) var notifiedUID: String?

    /// Call once per recording with the route it used. True: show the hint now.
    mutating func shouldNotify(pinnedUID: String?, route: InputRoute) -> Bool {
        guard let pinnedUID, route.isFallback else {
            notifiedUID = nil
            return false
        }
        guard notifiedUID != pinnedUID else { return false }
        notifiedUID = pinnedUID
        return true
    }

    static let hudLabel = "改用預設麥克風"
}

// MARK: - Read-only Core Audio queries

/// Reads the device list and defaults. Never changes anything, never opens a device (safe to call
/// any time, including from tests). Changes live in `CoreAudioOutputPort` (app only).
enum CoreAudioQuery {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func uint32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func float32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        // Core Audio hands out a retained CFString for these properties.
        return value.takeRetainedValue() as String
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    /// Channels of all streams in `scope` (input or output).
    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transport(_ device: AudioDeviceID) -> AudioTransport {
        AudioTransport(rawValue: uint32(device, address(kAudioDevicePropertyTransportType)) ?? 0)
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func name(_ device: AudioDeviceID) -> String? {
        string(device, kAudioObjectPropertyName) ?? string(device, kAudioDevicePropertyDeviceNameCFString)
    }

    static func isAlive(_ device: AudioDeviceID) -> Bool {
        (uint32(device, address(kAudioDevicePropertyDeviceIsAlive)) ?? 1) != 0
    }

    /// System plumbing nobody picks on purpose: hidden devices, and the private aggregates Core
    /// Audio creates for voice processing ("CADefaultDeviceAggregate-…").
    static func isPlumbing(uid: String, hidden: Bool) -> Bool {
        hidden || uid.hasPrefix("CADefaultDeviceAggregate")
    }

    /// Every live device with input channels, built-in first, then by name.
    static func inputDevices() -> [AudioInputDevice] {
        var devices: [AudioInputDevice] = []
        for id in deviceIDs() {
            let channels = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            guard channels > 0, isAlive(id), let uid = uid(id) else { continue }
            let hidden = (uint32(id, address(kAudioDevicePropertyIsHidden)) ?? 0) != 0
            guard !isPlumbing(uid: uid, hidden: hidden) else { continue }
            devices.append(AudioInputDevice(id: id, uid: uid, name: name(id) ?? uid, transport: transport(id),
                                            inputChannels: channels))
        }
        return devices.sorted { a, b in
            if (a.transport == .builtIn) != (b.transport == .builtIn) { return a.transport == .builtIn }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        systemDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        systemDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        guard let id = uint32(AudioObjectID(kAudioObjectSystemObject), address(selector)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// The device with `uid` among the current devices.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { self.uid($0) == uid }
    }

    /// Where the default output plays (see `OutputKind`).
    static func defaultOutputKind() -> OutputKind {
        guard let id = defaultOutputDeviceID() else { return .unknown }
        let source = uint32(id, address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput))
        return OutputKind.classify(transport: transport(id), dataSource: source)
    }
}
