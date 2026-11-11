import Foundation
import XCTest

/// Every UserDefaults suite the tests create starts with this prefix, so a preference
/// file left behind in ~/Library/Preferences is easy to recognise (CI fails on one).
let isolatedTestDefaultsPrefix = "CopyClipLiteTestDefaults-"

extension XCTestCase {
    /// Returns a real, empty UserDefaults suite private to the running test.
    ///
    /// The suite is removed when the test finishes, whether it passed, failed or threw.
    /// The cleanup runs as a teardown block, after the test method has returned and
    /// released the objects it created with these defaults.
    func makeIsolatedDefaults() -> UserDefaults {
        let suiteName: String = isolatedTestDefaultsPrefix + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults rejected the test suite name \(suiteName)")
        }
        let weakDefaults = WeakDefaultsBox()
        weakDefaults.value = defaults
        let testName: String = name
        addTeardownBlock {
            // TEMPORARY diagnostics for CI: is the suite's instance still alive here?
            if let path = ProcessInfo.processInfo.environment["COPYCLIP_DEFAULTS_DIAGNOSTICS_FILE"] {
                let state: String = weakDefaults.value == nil ? "released" : "alive"
                let line: String = "\(suiteName)\t\(state)\t\(testName)\n"
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try? handle.close()
                } else {
                    try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
                }
            }
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
            // removePersistentDomain(forName:) is deliberately not used: it only marks the
            // domain empty in this process, and that change reaches disk later (at the
            // latest when the process exits), recreating an empty plist after the file
            // below was deleted. Removing each key is written through by synchronize().
            let keys: [String] = defaults.persistentDomain(forName: suiteName)
                .map { Array($0.keys) } ?? []
            for key in keys {
                defaults.removeObject(forKey: key)
            }
            defaults.synchronize()
        }
        // cfprefsd keeps a plist for every domain that was ever written, even once empty.
        try? FileManager.default.removeItem(at: preferencesFileURL(forSuiteName: suiteName))
    }
}

// TEMPORARY diagnostics box.
final class WeakDefaultsBox: @unchecked Sendable {
    weak var value: UserDefaults?
}
