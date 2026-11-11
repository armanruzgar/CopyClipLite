import AppKit
import XCTest
@testable import CopyClipLite

private final class FaultInjectingPasteboard: ClipboardPasteboardAccess {
    private(set) var changeCount = 0
    private(set) var clearCount = 0
    private(set) var attemptedStrings: [String?] = []
    private(set) var currentString: String?
    var writeResults: [Bool] = []

    func clearPasteboardContents() -> Int {
        clearCount += 1
        changeCount += 1
        currentString = nil
        return changeCount
    }

    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        let string = items.first?.string(forType: .string)
        attemptedStrings.append(string)
        let result = writeResults.isEmpty ? true : writeResults.removeFirst()
        if result {
            currentString = string
        }
        return result
    }

    func simulateExternalChange(to string: String) {
        changeCount += 1
        currentString = string
    }
}

private final class BlockingPasteboard: ClipboardPasteboardAccess, @unchecked Sendable {
    let firstWriteStarted = DispatchSemaphore(value: 0)
    let allowFirstWrite = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var writeCount = 0
    private var storedChangeCount = 0

    var changeCount: Int {
        lock.withLock { storedChangeCount }
    }

    func clearPasteboardContents() -> Int {
        lock.withLock {
            storedChangeCount += 1
            return storedChangeCount
        }
    }

    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        let invocation = lock.withLock {
            writeCount += 1
            return writeCount
        }
        if invocation == 1 {
            firstWriteStarted.signal()
            allowFirstWrite.wait()
        }
        return true
    }

    var attemptedWriteCount: Int {
        lock.withLock { writeCount }
    }
}

final class ClipboardPasteboardWriterTests: XCTestCase {
    func testFailedWriteRestoresLastBoundedClipboardOwnedByWriter() {
        let pasteboard = FaultInjectingPasteboard()
        pasteboard.writeResults = [true, false, true]
        let writer = SystemClipboardPasteboardWriter(pasteboard: pasteboard)

        XCTAssertEqual(writer.write(request(text: "previous")), .success)
        XCTAssertEqual(writer.write(request(text: "replacement")), .failure)

        XCTAssertEqual(pasteboard.attemptedStrings, ["previous", "replacement", "previous"])
        XCTAssertEqual(pasteboard.currentString, "previous")
        XCTAssertEqual(pasteboard.clearCount, 3)
    }

    func testFailedWriteDoesNotMaterializeOrOverwriteSnapshotAfterExternalChange() {
        let pasteboard = FaultInjectingPasteboard()
        pasteboard.writeResults = [true, false]
        let writer = SystemClipboardPasteboardWriter(pasteboard: pasteboard)

        XCTAssertEqual(writer.write(request(text: "owned")), .success)
        pasteboard.simulateExternalChange(to: "external")
        XCTAssertEqual(writer.write(request(text: "replacement")), .failure)

        XCTAssertEqual(pasteboard.attemptedStrings, ["owned", "replacement"])
        XCTAssertNil(pasteboard.currentString)
        XCTAssertEqual(pasteboard.clearCount, 2)
    }

    func testOversizedOwnedClipboardIsNotRetainedForRollback() {
        let pasteboard = FaultInjectingPasteboard()
        pasteboard.writeResults = [true, false]
        let writer = SystemClipboardPasteboardWriter(
            pasteboard: pasteboard,
            maximumRollbackBytes: 4
        )

        XCTAssertEqual(writer.write(request(text: "12345")), .success)
        XCTAssertEqual(writer.write(request(text: "new")), .failure)

        XCTAssertEqual(pasteboard.attemptedStrings, ["12345", "new"])
        XCTAssertNil(pasteboard.currentString)
    }

    func testConcurrentWritesAreSerializedAroundRollbackState() {
        let pasteboard = BlockingPasteboard()
        let writer = SystemClipboardPasteboardWriter(pasteboard: pasteboard)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = writer.write(self.request(text: "first"))
            firstFinished.signal()
        }
        XCTAssertEqual(pasteboard.firstWriteStarted.wait(timeout: .now() + 10), .success)

        DispatchQueue.global().async {
            _ = writer.write(self.request(text: "second"))
            secondFinished.signal()
        }
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(pasteboard.attemptedWriteCount, 1)

        pasteboard.allowFirstWrite.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(pasteboard.attemptedWriteCount, 2)
    }

    private func request(text: String) -> ClipboardPasteboardWriteRequest {
        ClipboardPasteboardWriteRequest(
            required: [
                ClipboardPasteboardRepresentation(.string, value: .string(text))
            ],
            optional: []
        )
    }
}
