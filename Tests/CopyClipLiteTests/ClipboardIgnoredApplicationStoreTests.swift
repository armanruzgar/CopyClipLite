import Foundation
import XCTest

@testable import CopyClipLite

@MainActor
final class ClipboardIgnoredApplicationStoreTests: XCTestCase {
    func testFirstRunSeedsCredentialManagersAndPasswords() throws {
        let defaults = makeIsolatedDefaults()
        let store = ClipboardIgnoredApplicationStore(defaults: defaults)

        ClipboardDefaultExclusionsSeeder.seedIfNeeded(defaults: defaults, store: store)

        XCTAssertEqual(
            Set(store.load().map(\.bundleIdentifier)),
            Set(ClipboardDefaultExclusionsSeeder.applications.map(\.bundleIdentifier))
        )
        XCTAssertEqual(store.load().count, 8)
    }

    func testRemovedDefaultIsNotRestoredAfterInitialSeed() throws {
        let defaults = makeIsolatedDefaults()
        let store = ClipboardIgnoredApplicationStore(defaults: defaults)
        ClipboardDefaultExclusionsSeeder.seedIfNeeded(defaults: defaults, store: store)
        let removedIdentifier = "com.1password.1password"
        store.save(store.load().filter { $0.bundleIdentifier != removedIdentifier })

        ClipboardDefaultExclusionsSeeder.seedIfNeeded(defaults: defaults, store: store)

        XCTAssertFalse(store.load().contains { $0.bundleIdentifier == removedIdentifier })
        XCTAssertEqual(store.load().count, 7)
    }

    func testSeedPreservesExistingCustomExclusion() throws {
        let defaults = makeIsolatedDefaults()
        let store = ClipboardIgnoredApplicationStore(defaults: defaults)
        let custom = ClipboardSourceApplication(
            bundleIdentifier: "com.example.CustomSecrets",
            name: "Custom Secrets"
        )
        store.save([custom])

        ClipboardDefaultExclusionsSeeder.seedIfNeeded(defaults: defaults, store: store)

        XCTAssertTrue(store.load().contains(custom))
        XCTAssertEqual(store.load().count, 9)
    }
}
