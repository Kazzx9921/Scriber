import AVFoundation
import UIKit
import ScriberCore
import ScriberShared

/// Formatting helpers for `DiagLog` lines written by the engine and the recorder.
/// Everything here turns state into short, content-free tokens: ids, numbers, enum names,
/// error domains and codes. Nothing that the user said or typed ever passes through it.
enum EngineDiag {
    /// First 8 characters of a request id: enough to match keyboard and app lines.
    static func id(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "-" }
        return String(id.prefix(8))
    }

    @MainActor
    static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    static func millis(since start: Date, now: Date = Date()) -> Int {
        Int((now.timeIntervalSince(start) * 1000).rounded())
    }

    static func millis(sinceUptime start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    /// `domain=NSOSStatusErrorDomain code=561145187('!rec')`, plus the underlying error if any.
    static func error(_ error: Error) -> String {
        let ns = error as NSError
        var text = "domain=\(ns.domain) code=\(ns.code)\(fourCC(ns.code).map { "('\($0)')" } ?? "")"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " underlying=\(underlying.domain)/\(underlying.code)\(fourCC(underlying.code).map { "('\($0)')" } ?? "")"
        }
        return text
    }

    /// Core Audio packs many status codes as four printable characters ('!rec', 'what', '!pla').
    static func fourCC(_ code: Int) -> String? {
        guard code > 0, code <= Int(UInt32.max) else { return nil }
        let value = UInt32(code)
        let bytes = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// The error's type, never its message (server messages could echo anything).
    static func errorType(_ error: Error) -> String {
        if let provider = error as? ProviderError {
            switch provider {
            case .missingAPIKey(let kind): return "ProviderError.missingAPIKey(\(kind.rawValue))"
            case .http(let status, _): return "ProviderError.http(\(status))"
            case .network(let code): return "ProviderError.network(\(code))"
            case .emptyResult: return "ProviderError.emptyResult"
            case .cancelled: return "ProviderError.cancelled"
            }
        }
        if let polish = error as? PolishError {
            switch polish {
            case .requiresLLM(let mode): return "PolishError.requiresLLM(\(mode.rawValue))"
            case .refused: return "PolishError.refused"
            case .truncated: return "PolishError.truncated"
            case .invalidOutput: return "PolishError.invalidOutput"
            }
        }
        if let url = error as? URLError { return "URLError(\(url.code.rawValue))" }
        if error is CancellationError { return "CancellationError" }
        let ns = error as NSError
        return "\(String(describing: type(of: error))) \(ns.domain)/\(ns.code)"
    }

    // MARK: Audio session

    static func category(_ category: AVAudioSession.Category) -> String {
        category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
    }

    static func mode(_ mode: AVAudioSession.Mode) -> String {
        mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")
    }

    static func options(_ options: AVAudioSession.CategoryOptions) -> String {
        var names: [String] = []
        if options.contains(.mixWithOthers) { names.append("mixWithOthers") }
        if options.contains(.duckOthers) { names.append("duckOthers") }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) { names.append("interruptSpokenAudio") }
        if options.contains(.allowBluetoothA2DP) { names.append("allowBluetoothA2DP") }
        if options.contains(.defaultToSpeaker) { names.append("defaultToSpeaker") }
        if options.contains(.allowAirPlay) { names.append("allowAirPlay") }
        if options.contains(.overrideMutedMicrophoneInterruption) { names.append("overrideMutedMic") }
        let known: AVAudioSession.CategoryOptions = [.mixWithOthers, .duckOthers, .interruptSpokenAudioAndMixWithOthers,
                                                    .allowBluetoothA2DP, .defaultToSpeaker, .allowAirPlay,
                                                    .overrideMutedMicrophoneInterruption]
        let rest = options.subtracting(known).rawValue
        if rest != 0 { names.append("raw=\(rest)") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    /// Port types only. Port *names* can contain the owner's name ("Kazen's AirPods").
    static func route(_ route: AVAudioSessionRouteDescription = AVAudioSession.sharedInstance().currentRoute) -> String {
        let inputs = route.inputs.map(\.portType.rawValue).joined(separator: "+")
        let outputs = route.outputs.map(\.portType.rawValue).joined(separator: "+")
        return "in=\(inputs.isEmpty ? "none" : inputs) out=\(outputs.isEmpty ? "none" : outputs)"
    }

    static func routeChangeReason(_ raw: UInt) -> String {
        switch AVAudioSession.RouteChangeReason(rawValue: raw) {
        case .newDeviceAvailable: return "newDevice"
        case .oldDeviceUnavailable: return "oldDeviceGone"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "routeConfigChange"
        case .unknown, .none: return "unknown(\(raw))"
        @unknown default: return "raw(\(raw))"
        }
    }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)(\(build))"
    }
}
