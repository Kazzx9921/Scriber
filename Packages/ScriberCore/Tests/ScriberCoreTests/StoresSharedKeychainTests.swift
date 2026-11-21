import Security
import XCTest
@testable import ScriberCore
import ScriberShared

/// Moving API keys into the keychain group shared with the keyboard. `swift test` has no
/// entitlements, so this runs against a fake keychain that models access groups the way iOS
/// does: each process sees its own groups, a query without a group searches all of them, and an
/// add without a group goes to the first one.
final class StoresSharedKeychainTests: XCTestCase {
    private let shared = "TEAMID.com.geekaz.Scriber.shared"
    private let appID = "TEAMID.com.geekaz.Scriber"
    private let keyboardID = "TEAMID.com.geekaz.Scriber.Keyboard"
    private let appGroup = "group.com.geekaz.Scriber"
    private let service = "com.geekaz.Scriber.apikeys"
    private var keychain: FakeKeychain!
    private var logs: [String] = []

    override func setUp() {
        super.setUp()
        keychain = FakeKeychain()
        logs = []
    }

    /// The app after the update: the shared group is first in keychain-access-groups.
    private func app(failAddsTo: Set<String> = []) -> KeychainStore {
        KeychainStore(service: service, accessGroup: shared,
                      backend: keychain.backend(groups: [shared, appID, appGroup], failAddsTo: failAddsTo),
                      log: { [unowned self] in logs.append($0) })
    }

    private func keyboard() -> KeychainStore {
        KeychainStore(service: service, accessGroup: shared,
                      backend: keychain.backend(groups: [shared, keyboardID, appGroup]),
                      log: { [unowned self] in logs.append($0) })
    }

    /// What the build before this change wrote: no group → the app's application identifier.
    private func seedLegacy(_ value: String, kind: APIKeyKind) {
        keychain.items.append(.init(group: appID, service: service, account: kind.rawValue, data: Data(value.utf8)))
    }

    func testLegacyKeyMovesToSharedGroupAndKeyboardCanReadIt() {
        seedLegacy("sk-eleven", kind: .elevenLabs)
        seedLegacy("gsk-groq", kind: .groq)
        XCTAssertNil(keyboard().key(for: .groq), "before migration the keyboard cannot see the app's own group")
        XCTAssertEqual(keychain.items.count, 2, "the keyboard's no-op migration must not touch anything")

        let store = app()
        XCTAssertEqual(store.key(for: .groq), "gsk-groq")
        XCTAssertEqual(Set(keychain.items.map(\.group)), [shared])
        XCTAssertEqual(keychain.items.count, 2)
        XCTAssertEqual(keyboard().key(for: .elevenLabs), "sk-eleven")
        XCTAssertEqual(keyboard().key(for: .groq), "gsk-groq")
        XCTAssertNil(keyboard().key(for: .anthropic))
    }

    func testMigrationIsIdempotent() {
        seedLegacy("gsk-groq", kind: .groq)
        let store = app()
        XCTAssertEqual(store.migrateLegacyItems(), [.groq])
        let after = keychain.items
        XCTAssertEqual(store.migrateLegacyItems(), [])
        XCTAssertEqual(app().migrateLegacyItems(), [])
        XCTAssertEqual(keyboard().migrateLegacyItems(), [])
        XCTAssertEqual(keychain.items, after)
        XCTAssertEqual(app().key(for: .groq), "gsk-groq")
    }

    func testSharedCopyWinsOverLegacy() {
        seedLegacy("old", kind: .anthropic)
        keychain.items.append(.init(group: shared, service: service, account: APIKeyKind.anthropic.rawValue, data: Data("new".utf8)))
        XCTAssertEqual(app().key(for: .anthropic), "new")
        XCTAssertEqual(keychain.items.map(\.group), [shared])
    }

    func testLegacyIsKeptWhenSharedGroupIsUnusable() {
        // E.g. the entitlement did not make it into the signed build.
        seedLegacy("gsk-groq", kind: .groq)
        let store = app(failAddsTo: [shared])
        XCTAssertEqual(store.key(for: .groq), "gsk-groq", "the app keeps working with its old item")
        XCTAssertEqual(keychain.items.map(\.group), [appID], "nothing deleted without a verified copy")
        XCTAssertNil(store.accessGroup, "falls back to the default group for the rest of the process")
        store.setKey("gsk-new", for: .groq)
        XCTAssertEqual(store.key(for: .groq), "gsk-new")
        XCTAssertTrue(logs.contains { $0.contains("status=\(errSecMissingEntitlement)") })
    }

    func testSetKeyWritesSharedGroupAndRemovesLegacyCopies() {
        seedLegacy("stale", kind: .elevenLabs)
        // setKey migrates first, then overwrites: one item, in the shared group, with the new value.
        let store = app()
        store.setKey("  sk-fresh\n", for: .elevenLabs)
        XCTAssertEqual(keychain.items.count, 1)
        XCTAssertEqual(keychain.items.first?.group, shared)
        XCTAssertEqual(keyboard().key(for: .elevenLabs), "sk-fresh")

        seedLegacy("stale-again", kind: .elevenLabs) // written by an older build after a downgrade
        store.setKey(nil, for: .elevenLabs)
        XCTAssertTrue(keychain.items.isEmpty, "delete removes every visible copy")
        XCTAssertNil(store.key(for: .elevenLabs))
    }

    func testKeyboardWritesGoToSharedGroup() {
        let kb = keyboard()
        kb.setKey("from-keyboard", for: .groq)
        XCTAssertEqual(keychain.items.map(\.group), [shared])
        XCTAssertEqual(app().key(for: .groq), "from-keyboard")
    }

    func testNoValueEverReachesTheLog() {
        seedLegacy("sk-secret-value", kind: .groq)
        _ = app(failAddsTo: [shared]).key(for: .groq)
        _ = app().key(for: .groq)
        XCTAssertFalse(logs.isEmpty)
        XCTAssertFalse(logs.joined().contains("sk-secret"))
    }

    func testSharedAccessGroupNeedsAResolvedTeamPrefix() {
        // The test bundle has no Info.plist key: group-less, i.e. exactly the old behaviour.
        XCTAssertNil(KeychainStore.sharedAccessGroup)
        XCTAssertNil(KeychainStore(service: "x").accessGroup)
    }
}

/// In-memory keychain shared by several fake "processes".
final class FakeKeychain {
    struct Item: Equatable {
        var group: String
        var service: String
        var account: String
        var data: Data
    }

    var items: [Item] = []

    func backend(groups: [String], failAddsTo: Set<String> = []) -> KeychainBackend {
        func matches(_ item: Item, _ query: [String: Any]) -> Bool {
            if let service = query[kSecAttrService as String] as? String, service != item.service { return false }
            if let account = query[kSecAttrAccount as String] as? String, account != item.account { return false }
            if let group = query[kSecAttrAccessGroup as String] as? String, group != item.group { return false }
            return groups.contains(item.group)
        }
        func entitled(_ query: [String: Any]) -> Bool {
            guard let group = query[kSecAttrAccessGroup as String] as? String else { return true }
            return groups.contains(group)
        }
        return KeychainBackend(
            copyMatching: { [unowned self] query in
                guard entitled(query) else { return (errSecMissingEntitlement, nil) }
                let found = items.filter { matches($0, query) }
                guard let first = found.first else { return (errSecItemNotFound, nil) }
                let all = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
                if query[kSecReturnData as String] as? Bool == true {
                    return (errSecSuccess, first.data as NSData)
                }
                let attributes: [[String: Any]] = found.map {
                    [kSecAttrAccessGroup as String: $0.group, kSecAttrService as String: $0.service,
                     kSecAttrAccount as String: $0.account]
                }
                return (errSecSuccess, (all ? attributes as NSArray : attributes[0] as NSDictionary))
            },
            add: { [unowned self] query in
                let group = (query[kSecAttrAccessGroup as String] as? String) ?? groups[0]
                guard groups.contains(group), !failAddsTo.contains(group) else { return errSecMissingEntitlement }
                let service = query[kSecAttrService as String] as? String ?? ""
                let account = query[kSecAttrAccount as String] as? String ?? ""
                if items.contains(where: { $0.group == group && $0.service == service && $0.account == account }) {
                    return errSecDuplicateItem
                }
                items.append(Item(group: group, service: service, account: account,
                                  data: query[kSecValueData as String] as? Data ?? Data()))
                return errSecSuccess
            },
            update: { [unowned self] query, changes in
                guard entitled(query) else { return errSecMissingEntitlement }
                var hit = false
                for i in items.indices where matches(items[i], query) {
                    if let data = changes[kSecValueData as String] as? Data { items[i].data = data }
                    hit = true
                }
                return hit ? errSecSuccess : errSecItemNotFound
            },
            delete: { [unowned self] query in
                guard entitled(query) else { return errSecMissingEntitlement }
                let before = items.count
                items.removeAll { matches($0, query) }
                return items.count == before ? errSecItemNotFound : errSecSuccess
            }
        )
    }
}
