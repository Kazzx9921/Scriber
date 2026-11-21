import Security
import XCTest
@testable import ScriberCore
import ScriberShared

final class StoresKeychainTests: XCTestCase {
    private var store: KeychainStore!
    private var service: String!

    override func setUpWithError() throws {
        service = "com.geekaz.Scriber.tests.keychain.\(UUID().uuidString)"
        store = KeychainStore(service: service)
        // Unsigned test runners (CI, some sandboxes) may have no usable keychain.
        let status = store.storeKey("probe", for: .groq)
        guard status == errSecSuccess, store.key(for: .groq) == "probe" else {
            throw XCTSkip("Keychain unavailable in this test runner (OSStatus \(status)).")
        }
        store.setKey(nil, for: .groq)
    }

    override func tearDown() {
        for kind in APIKeyKind.allCases { store?.setKey(nil, for: kind) }
        super.tearDown()
    }

    func testSetReadUpdateDelete() {
        XCTAssertNil(store.key(for: .elevenLabs))
        XCTAssertFalse(store.hasKey(for: .elevenLabs))

        store.setKey("sk-test-one", for: .elevenLabs)
        XCTAssertEqual(store.key(for: .elevenLabs), "sk-test-one")
        XCTAssertTrue(store.hasKey(for: .elevenLabs))

        store.setKey("sk-test-two", for: .elevenLabs)
        XCTAssertEqual(store.key(for: .elevenLabs), "sk-test-two")

        store.setKey(nil, for: .elevenLabs)
        XCTAssertNil(store.key(for: .elevenLabs))
        store.setKey("sk-again", for: .elevenLabs)
        store.setKey("", for: .elevenLabs)
        XCTAssertNil(store.key(for: .elevenLabs))
        // Deleting something that is not there is fine.
        XCTAssertEqual(store.storeKey(nil, for: .elevenLabs), errSecSuccess)
    }

    func testKindsAndServicesAreIsolated() {
        store.setKey("groq-key", for: .groq)
        store.setKey("anthropic-key", for: .anthropic)
        XCTAssertEqual(store.key(for: .groq), "groq-key")
        XCTAssertEqual(store.key(for: .anthropic), "anthropic-key")
        XCTAssertNil(store.key(for: .elevenLabs))

        let other = KeychainStore(service: service + ".other")
        XCTAssertNil(other.key(for: .groq))
        // Same service from another instance sees the same items.
        XCTAssertEqual(KeychainStore(service: service).key(for: .groq), "groq-key")
    }

    func testWhitespaceIsTrimmedAndUnicodeSurvives() {
        store.setKey("  sk-pasted-key\n", for: .groq)
        XCTAssertEqual(store.key(for: .groq), "sk-pasted-key")
        store.setKey("   \n", for: .groq)
        XCTAssertNil(store.key(for: .groq))
        store.setKey("鍵-🔑-key", for: .groq)
        XCTAssertEqual(store.key(for: .groq), "鍵-🔑-key")
    }

    func testItemIsReadableAfterFirstUnlock() throws {
        store.setKey("sk-attr", for: .anthropic)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service!,
            kSecAttrAccount as String: APIKeyKind.anthropic.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        if let accessible = attributes[kSecAttrAccessible as String] as? String {
            XCTAssertEqual(accessible, kSecAttrAccessibleAfterFirstUnlock as String)
        } else {
            #if os(iOS)
            XCTFail("kSecAttrAccessible missing")
            #endif
            // The macOS file-based keychain used by unsigned test runners does not report it.
        }
    }
}
