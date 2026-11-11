import AppKit
import Foundation
import XCTest

@testable import CopyClipLite

/// A pasteboard that can be read from the capture queue while the test mutates it.
/// An armed gate parks the first background read until the test releases it.
final class ThreadSafeCapturePasteboard: ClipboardStorePasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NSPasteboard.PasteboardType: Data] = [:]
    private var storedChangeCount = 0
    private var gate: DispatchSemaphore?
    let backgroundReadStarted = DispatchSemaphore(value: 0)
    /// Signalled after each change-count read made off the main thread, once its value is fixed.
    let backgroundChangeCountRead = DispatchSemaphore(value: 0)

    var changeCount: Int {
        let value = lock.withLock { storedChangeCount }
        if !Thread.isMainThread {
            backgroundChangeCountRead.signal()
        }
        return value
    }

    var types: [NSPasteboard.PasteboardType]? {
        lock.withLock { values.isEmpty ? nil : Array(values.keys) }
    }

    func armGate() -> DispatchSemaphore {
        let release = DispatchSemaphore(value: 0)
        lock.withLock { gate = release }
        return release
    }

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        if !Thread.isMainThread,
           let gate = lock.withLock({ () -> DispatchSemaphore? in
               defer { self.gate = nil }
               return self.gate
           }) {
            backgroundReadStarted.signal()
            gate.wait()
        }
        return lock.withLock { values[dataType] }
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        data(forType: dataType).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    func clearPasteboardContents() -> Int {
        lock.withLock {
            values.removeAll()
            storedChangeCount += 1
            return storedChangeCount
        }
    }

    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        guard let item = items.first else { return false }
        lock.withLock {
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            storedChangeCount += 1
        }
        return true
    }

    func setData(_ data: Data, forType dataType: NSPasteboard.PasteboardType) {
        lock.withLock {
            values[dataType] = data
            storedChangeCount += 1
        }
    }

    func replaceContents(with string: String) {
        lock.withLock {
            values = [.string: Data(string.utf8)]
            storedChangeCount += 1
        }
    }
}

@MainActor
extension ClipboardStoreTests {
    private func makeBackgroundCaptureStore(
        pasteboard: ThreadSafeCapturePasteboard,
        defaults: UserDefaults? = nil
    ) throws -> ClipboardStore {
        ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults ?? makeDefaults(),
            sourceApplicationProvider: { nil },
            captureExecution: .background
        )
    }

    private func waitUntil(
        _ description: String,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description)")
    }

    private func waitForBackgroundSignal(_ semaphore: DispatchSemaphore) {
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success)
    }

    /// Captures `text` and waits for it; a read issued earlier is delivered first.
    private func captureSentinel(
        _ text: String,
        in store: ClipboardStore,
        pasteboard: ThreadSafeCapturePasteboard
    ) async throws {
        pasteboard.replaceContents(with: text)
        store.pollPasteboardForChanges()
        try await waitUntil(text) { store.items.contains { $0.text == text } }
    }

    func testBackgroundCaptureIsRecordedAfterTheHopToTheMainActor() async throws {
        let pasteboard = ThreadSafeCapturePasteboard()
        let store = try makeBackgroundCaptureStore(pasteboard: pasteboard)
        defer { store.setMonitoringEnabled(false) }

        pasteboard.replaceContents(with: "background text")
        store.pollPasteboardForChanges()

        XCTAssertTrue(store.items.isEmpty)
        try await waitUntil("background capture") { !store.items.isEmpty }
        XCTAssertEqual(store.items.map(\.text), ["background text"])
    }

    func testBackgroundCaptureIsDiscardedWhenThePasteboardChangesDuringTheRead() async throws {
        let pasteboard = ThreadSafeCapturePasteboard()
        let store = try makeBackgroundCaptureStore(pasteboard: pasteboard)
        defer { store.setMonitoringEnabled(false) }
        pasteboard.replaceContents(with: "stale value")
        let release = pasteboard.armGate()

        store.pollPasteboardForChanges()
        waitForBackgroundSignal(pasteboard.backgroundReadStarted)
        pasteboard.replaceContents(with: "newer value")
        release.signal()
        waitForBackgroundSignal(pasteboard.backgroundChangeCountRead)
        waitForBackgroundSignal(pasteboard.backgroundChangeCountRead)

        // Delivered after the stale read, so the stale snapshot would show up first.
        store.pollPasteboardForChanges()
        try await waitUntil("newer value") { !store.items.isEmpty }
        XCTAssertEqual(store.items.map(\.text), ["newer value"])
        XCTAssertEqual(store.items.first?.copyCount, 1)
    }

    func testBackgroundCaptureIsDiscardedWhenMonitoringIsPausedDuringTheRead() async throws {
        let pasteboard = ThreadSafeCapturePasteboard()
        let store = try makeBackgroundCaptureStore(pasteboard: pasteboard)
        defer { store.setMonitoringEnabled(false) }
        pasteboard.replaceContents(with: "captured before pause")
        let release = pasteboard.armGate()

        store.pollPasteboardForChanges()
        waitForBackgroundSignal(pasteboard.backgroundReadStarted)
        store.pauseMonitoring(for: .fiveMinutes)
        release.signal()
        store.setMonitoringEnabled(true)
        try await captureSentinel("after resume", in: store, pasteboard: pasteboard)

        XCTAssertEqual(store.items.map(\.text), ["after resume"])
    }

    func testBackgroundCaptureIsDiscardedWhenTheSourceAppIsIgnoredDuringTheRead() async throws {
        let pasteboard = ThreadSafeCapturePasteboard()
        let store = try makeBackgroundCaptureStore(pasteboard: pasteboard)
        defer { store.setMonitoringEnabled(false) }
        let secretApplication = ClipboardSourceApplication(
            bundleIdentifier: "com.example.BackgroundSecret",
            name: "Background Secret"
        )
        pasteboard.replaceContents(with: "secret value")
        let release = pasteboard.armGate()

        store.pollPasteboardForChanges(sourceApplicationOverride: secretApplication)
        waitForBackgroundSignal(pasteboard.backgroundReadStarted)
        store.addIgnoredApplication(secretApplication)
        release.signal()
        try await captureSentinel("public value", in: store, pasteboard: pasteboard)

        XCTAssertEqual(store.items.map(\.text), ["public value"])
    }

    func testBackgroundCapturesAreRecordedInTheOrderTheyWereObserved() async throws {
        let pasteboard = ThreadSafeCapturePasteboard()
        let store = try makeBackgroundCaptureStore(pasteboard: pasteboard)
        defer { store.setMonitoringEnabled(false) }

        pasteboard.replaceContents(with: "first")
        store.pollPasteboardForChanges()
        // Both change-count checks of the first read are done, so its snapshot stands
        // even though the second copy lands before either result reaches the main actor.
        waitForBackgroundSignal(pasteboard.backgroundChangeCountRead)
        waitForBackgroundSignal(pasteboard.backgroundChangeCountRead)
        pasteboard.replaceContents(with: "second")
        store.pollPasteboardForChanges()
        XCTAssertTrue(store.items.isEmpty)

        try await waitUntil("both captures") { store.items.count == 2 }
        XCTAssertEqual(store.items.map(\.text), ["second", "first"])
        XCTAssertGreaterThanOrEqual(store.items[0].lastCopiedAt, store.items[1].lastCopiedAt)
    }

    func testBackgroundCaptureCompletingAfterQuitCleanupIsDiscarded() async throws {
        let pasteboard = ThreadSafeCapturePasteboard()
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        let store = try makeBackgroundCaptureStore(pasteboard: pasteboard, defaults: defaults)
        defer { store.setMonitoringEnabled(false) }
        pasteboard.replaceContents(with: "in flight at quit")
        let release = pasteboard.armGate()

        store.pollPasteboardForChanges()
        waitForBackgroundSignal(pasteboard.backgroundReadStarted)
        XCTAssertTrue(store.clearUnpinnedHistoryOnQuitIfNeeded())
        release.signal()
        try await captureSentinel("sentinel", in: store, pasteboard: pasteboard)

        XCTAssertEqual(store.items.map(\.text), ["sentinel"])
    }

    func testBackgroundCaptureDoesNotResurrectAClipDeletedDuringTheRead() async throws {
        let pasteboard = ThreadSafeCapturePasteboard()
        let store = try makeBackgroundCaptureStore(pasteboard: pasteboard)
        defer { store.setMonitoringEnabled(false) }
        try await captureSentinel("deleted value", in: store, pasteboard: pasteboard)
        let deletedItem = try XCTUnwrap(store.items.first)
        pasteboard.replaceContents(with: "deleted value")
        let release = pasteboard.armGate()

        store.pollPasteboardForChanges()
        waitForBackgroundSignal(pasteboard.backgroundReadStarted)
        let deleted = await store.delete(deletedItem)
        XCTAssertTrue(deleted)
        release.signal()
        try await captureSentinel("sentinel", in: store, pasteboard: pasteboard)

        XCTAssertEqual(store.items.map(\.text), ["sentinel"])
    }

    func testBackgroundCaptureSkipsOversizedRepresentationAndKeepsTheSmallerOne() async throws {
        let pasteboard = ThreadSafeCapturePasteboard()
        let store = try makeBackgroundCaptureStore(pasteboard: pasteboard)
        defer { store.setMonitoringEnabled(false) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: makePNGData(width: 5, height: 2)))
        let tiffData = try XCTUnwrap(bitmap.tiffRepresentation)
        pasteboard.clearPasteboardContents()
        pasteboard.setData(
            Data(repeating: 0xFF, count: ClipboardImageProcessor.maximumInputBytes + 1),
            forType: .png
        )
        pasteboard.setData(tiffData, forType: .tiff)

        let read = ClipboardCaptureReader.imageRead(from: pasteboard, fileURLs: [])
        XCTAssertTrue(read.skippedOversizedRepresentation)
        let sources = try XCTUnwrap(read.candidate?.sources)
        XCTAssertEqual(sources.count, 1)
        guard case let .data(data, isPNG) = try XCTUnwrap(sources.first) else {
            return XCTFail("Expected the TIFF data source")
        }
        XCTAssertEqual(data, tiffData)
        XCTAssertFalse(isPNG)

        store.pollPasteboardForChanges()
        try await waitUntil("image capture") { !store.items.isEmpty }

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.contentKind, .image)
        XCTAssertEqual(item.image?.width, 5)
        XCTAssertEqual(item.image?.height, 2)
        XCTAssertNil(store.captureWarning)
    }

    func testImageReadKeepsPNGAndOneFallbackRepresentation() throws {
        let pasteboard = ThreadSafeCapturePasteboard()
        let pngData = try makePNGData(width: 2, height: 2)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: pngData))
        pasteboard.setData(try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])),
                           forType: NSPasteboard.PasteboardType("public.jpeg"))
        pasteboard.setData(try XCTUnwrap(bitmap.tiffRepresentation), forType: .tiff)
        pasteboard.setData(pngData, forType: .png)

        let sources = try XCTUnwrap(
            ClipboardCaptureReader.imageRead(from: pasteboard, fileURLs: []).candidate?.sources
        )

        XCTAssertEqual(sources.count, 2)
        guard case let .data(firstData, firstIsPNG) = sources[0],
              case let .data(_, secondIsPNG) = sources[1] else {
            return XCTFail("Expected two in-memory sources")
        }
        XCTAssertEqual(firstData, pngData)
        XCTAssertTrue(firstIsPNG)
        XCTAssertFalse(secondIsPNG)
    }
}
