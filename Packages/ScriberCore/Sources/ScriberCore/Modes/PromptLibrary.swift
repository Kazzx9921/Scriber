import Foundation
import Observation
import ScriberShared

/// One prompt of the library: the user-editable style / format text a mode's AI step uses.
/// The safety wrapper around it is added in code (`PolishPrompt`) and is not part of `body`.
public struct PromptTemplate: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Fixed for shipped prompts. Decides the safety wrapper (only `.assistant` answers).
    public var kind: PromptKind
    /// Text with `{{selected}}`, `{{clipboard}}`, `{{app}}`, `{{language}}`, `{{spacing}}`.
    public var body: String

    public init(id: String = UUID().uuidString, name: String, kind: PromptKind = .dictation, body: String) {
        self.id = id; self.name = name; self.kind = kind; self.body = body
    }

    public var builtInID: BuiltInPromptID? { BuiltInPromptID(rawValue: id) }
    public var isBuiltIn: Bool { builtInID != nil }

    /// A shipped prompt whose name or text the user changed (「還原預設」 applies).
    public var isModified: Bool {
        guard let builtInID else { return false }
        let shipped = BuiltInPrompts.template(builtInID)
        return name != shipped.name || body != shipped.body
    }

    /// A shipped prompt exactly as shipped: its examples are added to the prompt.
    public var isPristineBuiltIn: Bool { isBuiltIn && !isModified }

    /// The variable names a body may use.
    public static let variables = ["selected", "clipboard", "app", "language", "spacing"]
}

public enum PromptLibraryError: Error, Equatable, Sendable {
    case notFound
    /// Shipped prompts can be edited and restored, not deleted.
    case builtInCannotBeDeleted
    /// 「還原預設」 only applies to shipped prompts.
    case notBuiltIn
    case emptyName
    case bodyTooLong
}

/// The prompt library (PRD §5), JSON in the App Group container (`prompts.json`; on macOS in
/// Application Support), readable by the keyboard extension.
///
/// Shipped prompts live in code; the file keeps only what the user changed about them (name and
/// text), so an app update that improves a shipped prompt reaches everyone who did not edit it.
/// Prompts the user made are stored in full. Same threading model as `DictionaryStore`.
@Observable
public final class PromptLibrary: @unchecked Sendable {
    public static let shared = PromptLibrary()
    public static let maxNameLength = 40
    /// Long enough for detailed instructions; keeps a pasted document from becoming a prompt.
    public static let maxBodyLength = 4000

    /// Shipped prompts first (fixed order), then the user's in the order they were made.
    public private(set) var prompts: [PromptTemplate] = []
    @ObservationIgnored private let list: PersistentList<StoredPrompt>
    @ObservationIgnored private var changeObserver: StoreChangeObserver?

    public init(fileURL: URL? = nil) {
        list = PersistentList(fileURL: fileURL ?? AppGroup.containerURL.appendingPathComponent("prompts.json"))
        prompts = Self.merge(list.read())
        changeObserver = StoreChangeObserver(name: list.changeNotificationName) { [weak self] in self?.publish() }
    }

    /// The shipped prompts as shipped.
    public static var builtIns: [PromptTemplate] { BuiltInPrompts.all }

    public static func builtIn(_ id: BuiltInPromptID) -> PromptTemplate { BuiltInPrompts.template(id) }

    /// Thread-safe snapshot for the pipeline.
    public func snapshot() -> [PromptTemplate] { Self.merge(list.read()) }

    public func prompt(id: String) -> PromptTemplate? { snapshot().first { $0.id == id } }

    public func reload() { publish() }

    /// Adds a prompt the user made. Returns it with its new id.
    @discardableResult
    public func add(name: String, kind: PromptKind = .dictation, body: String) throws -> PromptTemplate {
        let template = PromptTemplate(name: try Self.validName(name), kind: kind, body: try Self.validBody(body))
        list.mutate { $0.append(StoredPrompt(template)) }
        publish()
        return template
    }

    /// Saves a changed prompt. For shipped prompts only the name and text change (the kind is fixed).
    public func update(_ prompt: PromptTemplate) throws {
        let name = try Self.validName(prompt.name)
        let body = try Self.validBody(prompt.body)
        var failure: PromptLibraryError?
        list.mutate { stored in
            if let builtIn = prompt.builtInID {
                let shipped = BuiltInPrompts.template(builtIn)
                stored.removeAll { $0.id == prompt.id }
                let override = StoredPrompt(id: prompt.id, name: name == shipped.name ? nil : name,
                                            kind: nil, body: body == shipped.body ? nil : body)
                if override.name != nil || override.body != nil { stored.append(override) }
            } else if let index = stored.firstIndex(where: { $0.id == prompt.id }) {
                stored[index] = StoredPrompt(PromptTemplate(id: prompt.id, name: name, kind: prompt.kind, body: body))
            } else {
                failure = .notFound
            }
        }
        publish()
        if let failure { throw failure }
    }

    /// A copy the user owns (any prompt, shipped or not), added at the end.
    @discardableResult
    public func duplicate(id: String) throws -> PromptTemplate {
        guard let source = prompt(id: id) else { throw PromptLibraryError.notFound }
        return try add(name: source.name, kind: source.kind, body: source.body)
    }

    public func delete(id: String) throws {
        if BuiltInPromptID(rawValue: id) != nil { throw PromptLibraryError.builtInCannotBeDeleted }
        var found = false
        list.mutate { stored in
            found = stored.contains { $0.id == id }
            stored.removeAll { $0.id == id }
        }
        publish()
        if !found { throw PromptLibraryError.notFound }
    }

    /// Puts a shipped prompt back to its shipped name and text.
    public func restoreBuiltIn(id: String) throws {
        guard BuiltInPromptID(rawValue: id) != nil else { throw PromptLibraryError.notBuiltIn }
        list.mutate { $0.removeAll { $0.id == id } }
        publish()
    }

    // MARK: Private

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PromptLibraryError.emptyName }
        return String(trimmed.prefix(maxNameLength))
    }

    private static func validBody(_ body: String) throws -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maxBodyLength else { throw PromptLibraryError.bodyTooLong }
        return trimmed
    }

    /// Shipped prompts with the user's changes applied, then the user's own prompts (first copy of
    /// each id wins; records that cannot be a prompt are skipped).
    static func merge(_ stored: [StoredPrompt]) -> [PromptTemplate] {
        var overrides: [String: StoredPrompt] = [:]
        var custom: [PromptTemplate] = []
        var seen = Set<String>()
        for record in stored where !record.id.isEmpty && seen.insert(record.id).inserted {
            if BuiltInPromptID(rawValue: record.id) != nil {
                overrides[record.id] = record
            } else if let name = record.name, let body = record.body {
                custom.append(PromptTemplate(id: record.id, name: name, kind: record.kind ?? .dictation, body: body))
            }
        }
        let shipped = BuiltInPrompts.all.map { template -> PromptTemplate in
            guard let override = overrides[template.id] else { return template }
            var merged = template
            if let name = override.name, !name.isEmpty { merged.name = name }
            if let body = override.body { merged.body = body }
            return merged
        }
        return shipped + custom
    }

    private func publish() {
        if Thread.isMainThread {
            let latest = Self.merge(list.read())
            if latest != prompts { prompts = latest }
        } else {
            DispatchQueue.main.async { [self] in publish() }
        }
    }
}

/// What `prompts.json` holds: a user prompt in full, or the changed fields of a shipped one.
struct StoredPrompt: Codable, Equatable, Sendable {
    var id: String
    var name: String?
    var kind: PromptKind?
    var body: String?
    var version: Int = 1

    init(id: String, name: String?, kind: PromptKind?, body: String?) {
        self.id = id; self.name = name; self.kind = kind; self.body = body
    }

    init(_ template: PromptTemplate) {
        self.init(id: template.id, name: template.name, kind: template.kind, body: template.body)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        kind = (try? c.decodeIfPresent(PromptKind.self, forKey: .kind)) ?? nil
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? nil
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
    }
}
