import AppKit
import Foundation
import XCTest

@testable import CopyClipLite

private actor GatedFirstImageProcessor: ClipboardImageProcessing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false
    nonisolated let started = XCTestExpectation(description: "first image processing started")

    func process(_ candidate: ClipboardImageCandidate) async throws -> ClipboardImagePayload {
        if !hasStarted {
            hasStarted = true
            started.fulfill()
            await withCheckedContinuation { continuation = $0 }
        }
        return try ClipboardImageProcessor.process(candidate)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
extension ClipboardStoreTests {
    func testDeletingClipDiscardsOlderImageOrTextFallbackButAllowsUnrelatedAndFreshCaptures() async throws {
        for usesTextFallback in [false, true] {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            let png = try makePNGData(width: 3, height: 3)
            let payload = try ClipboardImageProcessor.process(ClipboardImageCandidate(data: png, isPNG: true))
            let original = usesTextFallback
                ? ClipboardItem(text: "deleted text")
                : ClipboardItem(image: payload)
            try storage.saveValidated([original])
            let board = makePasteboard()
            let processor = GatedFirstImageProcessor()
            let store = ClipboardStore(
                pasteboard: board, storage: storage, defaults: makeDefaults(),
                sourceApplicationProvider: { nil }, imageProcessor: processor
            )
            defer { store.setMonitoringEnabled(false) }

            let captureData = usesTextFallback ? Data("invalid image".utf8) : png
            board.setData(captureData, forType: .png)
            if usesTextFallback { board.setString(original.text, forType: .string) }
            store.pollPasteboardForChanges()
            try await waitForFirstImageProcessing(processor)
            board.setData(captureData, forType: .png)
            store.pollPasteboardForChanges()

            let sentinelData = try makePNGData(width: 4, height: 4)
            board.clearContents()
            board.setData(sentinelData, forType: .png)
            store.pollPasteboardForChanges()
            let deleted = await store.delete(original)
            XCTAssertTrue(deleted)
            XCTAssertTrue(storage.load().isEmpty)

            await processor.release()
            try await waitForHistoryCount(1, in: store)
            XCTAssertEqual(store.items.first?.image?.width, 4)
            let flushed = await store.flushPendingPersist()
            XCTAssertTrue(flushed)
            XCTAssertEqual(storage.load().count, 1)

            board.clearContents()
            board.setData(captureData, forType: .png)
            if usesTextFallback { board.setString(original.text, forType: .string) }
            store.pollPasteboardForChanges()
            try await waitForHistoryCount(2, in: store)
            XCTAssertTrue(store.items.contains {
                usesTextFallback ? $0.text == original.text : $0.image?.contentHash == payload.contentHash
            })
        }
    }

    func testNewExclusionDiscardsActiveAndQueuedImagesAndFallbackTextOnlyForThatSource() async throws {
        for usesTextFallback in [false, true] {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            let board = makePasteboard()
            let processor = GatedFirstImageProcessor()
            let excluded = ClipboardSourceApplication(bundleIdentifier: "test.excluded", name: "Excluded")
            let other = ClipboardSourceApplication(bundleIdentifier: "test.other", name: "Other")
            var source = excluded
            let store = ClipboardStore(
                pasteboard: board, storage: storage, defaults: makeDefaults(),
                sourceApplicationProvider: { source }, imageProcessor: processor
            )
            defer { store.setMonitoringEnabled(false) }
            let png = try makePNGData(width: 3, height: 3)
            let captureData = usesTextFallback ? Data("invalid image".utf8) : png
            board.setData(captureData, forType: .png)
            board.setString("excluded fallback", forType: .string)
            store.pollPasteboardForChanges()
            try await waitForFirstImageProcessing(processor)
            board.setData(captureData, forType: .png)
            store.pollPasteboardForChanges()

            source = other
            board.clearContents()
            board.setData(try makePNGData(width: 4, height: 4), forType: .png)
            store.pollPasteboardForChanges()
            store.addIgnoredApplication(excluded)
            await processor.release()
            try await waitForHistoryCount(1, in: store)
            XCTAssertEqual(store.items.first?.sourceApplication, other)
            let flushed = await store.flushPendingPersist()
            XCTAssertTrue(flushed)
            XCTAssertEqual(storage.load().map(\.sourceApplication), [other])

            store.removeIgnoredApplication(excluded)
            source = excluded
            board.clearContents()
            board.setData(captureData, forType: .png)
            board.setString("excluded fallback", forType: .string)
            store.pollPasteboardForChanges()
            try await waitForHistoryCount(2, in: store)
            XCTAssertTrue(store.items.contains { $0.sourceApplication == excluded })
        }
    }

    func testClearSurfacesImageCleanupFailurePurgesBackupsAndCanRetryAfterRelaunch() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        let image = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: makePNGData(width: 3, height: 3), isPNG: true)
        )
        let pinnedImage = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: makePNGData(width: 4, height: 4), isPNG: true)
        )
        let items = try storage.saveValidated([
            ClipboardItem(image: image), ClipboardItem(image: pinnedImage, isPinned: true)
        ])
        try storage.backup(items, reason: "pre-import")
        let store = ClipboardStore(
            pasteboard: makePasteboard(), storage: storage, defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let sidecar = storage.imageDirectoryURL.appendingPathComponent(try XCTUnwrap(items[0].image?.fileName))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: sidecar.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path) }

        let cleared = await store.clearHistory()

        XCTAssertFalse(cleared)
        XCTAssertEqual(store.items.map(\.id), [items[1].id])
        XCTAssertEqual(storage.load().map(\.id), [items[1].id])
        XCTAssertTrue(store.imageCleanupPending)
        XCTAssertEqual(store.storageErrorMessage, ClipboardStore.imageCleanupErrorMessage)
        XCTAssertEqual(try Data(contentsOf: sidecar), image.data)
        XCTAssertEqual(try storage.backupInventory().count, 0)
        XCTAssertEqual(storage.imageData(for: items[1]), pinnedImage.data)

        let reloadedStorage = ClipboardStorage(appDirectory: directory)
        XCTAssertEqual(try reloadedStorage.loadResult().get().map(\.id), [items[1].id])
        XCTAssertTrue(reloadedStorage.imageCleanupPending)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path)
        let retried = await store.retryImageCleanup()
        XCTAssertTrue(retried)
        XCTAssertFalse(store.imageCleanupPending)
        XCTAssertNil(store.storageErrorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(storage.imageData(for: items[1]), pinnedImage.data)
        store.setMonitoringEnabled(false)
    }

    func testImportRemainsCommittedWhenOldImageCleanupFails() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let payload = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: makePNGData(width: 3, height: 3), isPNG: true)
        )
        let oldItems = try storage.saveValidated([ClipboardItem(image: payload)])
        let store = ClipboardStore(
            pasteboard: makePasteboard(), storage: storage, defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let sidecar = storage.imageDirectoryURL.appendingPathComponent(try XCTUnwrap(oldItems[0].image?.fileName))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: sidecar.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path) }
        let replacement = ClipboardItem(text: "replacement")
        let artifact = try await store.prepareImport(
            data: ClipboardTransferCodec.encode([replacement]), sourceFileName: "replacement.json"
        )

        let commit = try await store.importHistory(artifact: artifact, strategy: .replace)

        XCTAssertEqual(commit.items, [replacement])
        XCTAssertEqual(store.items, [replacement])
        XCTAssertEqual(storage.load(), [replacement])
        XCTAssertTrue(store.imageCleanupPending)
        XCTAssertEqual(store.storageErrorMessage, ClipboardStore.imageCleanupErrorMessage)
        XCTAssertEqual(try storage.importItems(from: commit.backupURL).first?.image?.data, payload.data)
        store.setMonitoringEnabled(false)
    }

    func testQuitDoesNotRestoreDeletedRowsWhenImageCleanupFails() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let payload = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: makePNGData(width: 3, height: 3), isPNG: true)
        )
        let pinned = ClipboardItem(text: "keep pinned", isPinned: true)
        let items = try storage.saveValidated([ClipboardItem(image: payload), pinned])
        try storage.backup(items, reason: "pre-import")
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        let store = ClipboardStore(
            pasteboard: makePasteboard(), storage: storage, defaults: defaults,
            sourceApplicationProvider: { nil }
        )
        let sidecar = storage.imageDirectoryURL.appendingPathComponent(try XCTUnwrap(items[0].image?.fileName))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: sidecar.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: sidecar.path) }

        XCTAssertFalse(store.clearUnpinnedHistoryOnQuitIfNeeded())

        XCTAssertEqual(store.items, [pinned])
        XCTAssertEqual(storage.load(), [pinned])
        XCTAssertTrue(store.imageCleanupPending)
        XCTAssertEqual(try storage.backupInventory().count, 0)
        store.setMonitoringEnabled(false)
    }

    func testImageDirectoryEnumerationFailureIsVisibleAndRetryable() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        try storage.saveValidated([ClipboardItem(text: "text")])
        let store = ClipboardStore(
            pasteboard: makePasteboard(), storage: storage, defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        try FileManager.default.removeItem(at: storage.imageDirectoryURL)
        try Data("not a directory".utf8).write(to: storage.imageDirectoryURL)

        let cleared = await store.clearHistory()

        XCTAssertFalse(cleared)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.imageCleanupPending)
        try FileManager.default.removeItem(at: storage.imageDirectoryURL)
        try FileManager.default.createDirectory(at: storage.imageDirectoryURL, withIntermediateDirectories: true)
        let retried = await store.retryImageCleanup()
        XCTAssertTrue(retried)
        XCTAssertFalse(store.imageCleanupPending)
        store.setMonitoringEnabled(false)
    }

    func testMergePrefersExactIdentifierBeforeEqualTextImageOrLinkContent() async throws {
        let now = Date()
        let image = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: makePNGData(width: 3, height: 3), isPNG: true)
        )
        for kind: ClipboardContentKind in [.text, .image, .link] {
            func makeItem(id: UUID, date: Date, pinned: Bool, copies: Int) -> ClipboardItem {
                let created = now.addingTimeInterval(-60)
                switch kind {
                case .text:
                    return ClipboardItem(id: id, text: "same content", createdAt: created, lastCopiedAt: date, isPinned: pinned, copyCount: copies)
                case .image:
                    return ClipboardItem(id: id, image: image, createdAt: created, lastCopiedAt: date, isPinned: pinned, copyCount: copies)
                case .link:
                    return ClipboardItem(id: id, link: ClipboardLinkContent(url: URL(string: "https://example.invalid/clip")!, title: nil), createdAt: created, lastCopiedAt: date, isPinned: pinned, copyCount: copies)
                }
            }
            let first = makeItem(id: UUID(), date: now.addingTimeInterval(-10), pinned: true, copies: 2)
            let second = makeItem(id: UUID(), date: now.addingTimeInterval(-20), pinned: false, copies: 5)
            let incoming = makeItem(id: second.id, date: now, pinned: true, copies: 3)
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            try storage.saveValidated([first, second])
            let store = ClipboardStore(
                pasteboard: makePasteboard(), storage: storage, defaults: makeDefaults(),
                sourceApplicationProvider: { nil }
            )
            let artifact = try await store.prepareImport(
                data: ClipboardTransferCodec.encode([incoming]), sourceFileName: "merge.json"
            )
            let plan = store.importPlan(for: artifact)
            XCTAssertEqual(Set(plan.mergeItems.map(\.id)), [first.id, second.id])
            let commit = try await store.importHistory(plan: plan, strategy: .merge)
            XCTAssertEqual(commit.items.count, plan.mergeProjection.finalCount)
            XCTAssertEqual(Set(commit.items.map(\.id)), [first.id, second.id])
            let updated = try XCTUnwrap(commit.items.first { $0.id == second.id })
            XCTAssertEqual(updated.copyCount, 5)
            XCTAssertEqual(updated.lastCopiedAt, now)
            XCTAssertTrue(updated.isPinned)
            XCTAssertEqual(storage.load().count, 2)
            store.setMonitoringEnabled(false)
        }
    }

    func testPreviouslyStoredUnsupportedPinnedDateCanBeLoadedAndRendered() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let date = Date(timeIntervalSinceReferenceDate: -1e30)
        let item = ClipboardItem(text: "legacy invalid date", createdAt: date, lastCopiedAt: date, isPinned: true)
        try storage.saveValidated([item])
        let store = ClipboardStore(
            pasteboard: makePasteboard(), storage: storage, defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.lastCopiedDescription, "Unknown date")
        store.setMonitoringEnabled(false)
    }

    private func waitForFirstImageProcessing(_ processor: GatedFirstImageProcessor) async throws {
        await fulfillment(of: [processor.started], timeout: 10)
    }

    private func waitForHistoryCount(_ count: Int, in store: ClipboardStore) async throws {
        await waitForState(of: store, "\(count) history items") { store.items.count == count }
        XCTAssertEqual(store.items.count, count)
    }
}
