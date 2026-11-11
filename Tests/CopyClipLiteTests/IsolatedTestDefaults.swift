import Foundation
import XCTest

/// Every UserDefaults suite the tests create starts with this prefix, so a preference
/// file left behind in ~/Library/Preferences is easy to recognise (CI fails on one).
let isolatedTestDefaultsPrefix = "CopyClipLiteTestDefaults-"

extension XCTestCase {
    /// Returns a real, empty UserDefaults suite private to the running test.
    ///
    /// The suite is removed when the test finishes, whether it passed, failed or threw.
    /// Removing the persistent domain is not enough on its own: cfprefsd keeps a plist
    /// for every domain that was ever written, so the cleanup also deletes that file.
    /// The cleanup runs as a teardown block, after the test method has returned and
    /// released the objects it created with these defaults.
    func makeIsolatedDefaults() -> UserDefaults {
        let suiteName: String = isolatedTestDefaultsPrefix + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults rejected the test suite name \(suiteName)")
        }
        addTeardownBlock {
            IsolatedTestDefaults.remove(suiteName: suiteName)
        }
        return defaults
    }
}

enum IsolatedTestDefaults {
    static func preferencesFileURL(forSuiteName suiteName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(suiteName).plist", isDirectory: false)
    }

    static func remove(suiteName: String) {
        precondition(
            suiteName.hasPrefix(isolatedTestDefaultsPrefix),
            "Refusing to remove a preference domain the tests did not create: \(suiteName)"
        )
        if let defaults = UserDefaults(suiteName: suiteName) {
            // Flush writes still queued for cfprefsd so they cannot land after the removal.
            defaults.synchronize()
            defaults.removePersistentDomain(forName: suiteName)
            defaults.synchronize()
        }
        try? FileManager.default.removeItem(at: preferencesFileURL(forSuiteName: suiteName))
    }
}
