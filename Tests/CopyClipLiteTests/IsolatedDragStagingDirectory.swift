import Foundation
import XCTest

/// Every drag staging directory the tests create starts with this prefix, so anything
/// left behind is easy to recognise (CI fails on it).
let isolatedDragStagingPrefix = "CopyClipLiteTestDragStaging-"

extension XCTestCase {
    /// Returns a drag staging directory private to the running test.
    ///
    /// A `ClipboardStore` empties its drag staging directory when it is created. The
    /// installed app stages its drags in `$TMPDIR/CopyClipLite-Drag`, which the test
    /// process shares, so a store built with that directory could delete the files of a
    /// drag the real app has in progress. The directory returned here is removed when the
    /// test finishes, whether it passed, failed or threw.
    func makeIsolatedDragStagingDirectory() -> URL {
        let directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(isolatedDragStagingPrefix + UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
