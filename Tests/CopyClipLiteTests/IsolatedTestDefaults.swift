import Foundation
import XCTest

/// Every UserDefaults suite the tests create lives in a temporary directory whose name
/// starts with this prefix, so anything left behind is easy to recognise (CI fails on it).
let isolatedTestDefaultsPrefix = "CopyClipLiteTestDefaults-"

extension XCTestCase {
    /// Returns a real, empty UserDefaults suite private to the running test.
    ///
    /// The suite name is an absolute path inside a fresh temporary directory, so
    /// cfprefsd stores it there (as `defaults.plist`) instead of in
    /// ~/Library/Preferences. A named suite cannot be cleaned up reliably: once a
    /// process has written to it, cfprefsd writes its plist again when that process
    /// exits, as `{}` if the domain was removed, even if the file was deleted in
    /// between. A path suite is not written back that way, so deleting the directory
    /// when the test finishes, whether it passed, failed or threw, removes it for good.
    func makeIsolatedDefaults() -> UserDefaults {
        let directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(isolatedTestDefaultsPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("Could not create \(directory.path): \(error)")
        }
        let suiteName: String = directory.appendingPathComponent("defaults", isDirectory: false).path
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults rejected the test suite \(suiteName)")
        }
        // Teardown blocks run after the test method has returned, so the objects it
        // created with these defaults have been released by then.
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return defaults
    }
}
