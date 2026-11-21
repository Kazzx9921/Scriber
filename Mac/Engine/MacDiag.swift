import AppKit
import ScriberCore
import ScriberShared

/// Formatting helpers for `DiagLog` lines. Everything here turns state into short, content-free
/// tokens: ids, numbers, enum names, bundle ids, error domains and codes. Nothing the user said,
/// typed, selected or pasted ever passes through it, and neither do API keys.
enum MacDiag {
    /// First 8 characters of a request id.
    static func id(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "-" }
        return String(id.prefix(8))
    }

    static func millis(since start: Date, now: Date = Date()) -> Int {
        Int((now.timeIntervalSince(start) * 1000).rounded())
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
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
        if let custom = error as? CustomSTTError { return "CustomSTTError.\(custom)" }
        if let url = error as? URLError { return "URLError(\(url.code.rawValue))" }
        if error is CancellationError { return "CancellationError" }
        let ns = error as NSError
        return "\(String(describing: type(of: error))) \(ns.domain)/\(ns.code)"
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)(\(build))"
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Bundle id of an app, or "-".
    static func app(_ app: NSRunningApplication?) -> String {
        app?.bundleIdentifier ?? (app.map { "pid\($0.processIdentifier)" } ?? "-")
    }
}
