import AppKit
import Foundation
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
    // MARK: Recovered history

    func testQuarantinedHistoryPersistsNewClipsAndShowsNoticeUntilDismissed() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        try Data("not json".utf8).write(to: storage.fileURL, options: .atomic)
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }
        let notice = try XCTUnwrap(store.storageErrorMessage)
        XCTAssertTrue(notice.contains("moved to"))

        pasteboard.setString("after recovery", forType: .string)
        store.pollPasteboardForChanges()
        let saved = await store.flushPendingPersist()

        XCTAssertTrue(saved)
        XCTAssertEqual(storage.load().map(\.text), ["after recovery"])
        XCTAssertEqual(store.storageErrorMessage, notice)

        store.dismissStorageError()
        pasteboard.clearContents()
        pasteboard.setString("second clip", forType: .string)
        store.pollPasteboardForChanges()
        let savedAgain = await store.flushPendingPersist()

        XCTAssertTrue(savedAgain)
        XCTAssertNil(store.storageErrorMessage)
        XCTAssertEqual(storage.load().map(\.text), ["second clip", "after recovery"])
    }

    func testUnreadableHistoryStillBlocksPersistence() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "existing")])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storage.fileURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storage.fileURL.path
            )
        }
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }
        pasteboard.setString("new clip", forType: .string)
        store.pollPasteboardForChanges()

        let saved = await store.flushPendingPersist()

        XCTAssertFalse(saved)
        XCTAssertEqual(store.storageErrorMessage, ClipboardStorageError.unreadableHistory.localizedDescription)
    }

    // MARK: Mixed text and image copies

    func testOfficeCopyWithRichTextAndRenderedImageIsRecordedAsText() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }
        let rtfData = try XCTUnwrap(
            NSAttributedString(string: "Q3 revenue").rtf(
                from: NSRange(location: 0, length: 10),
                documentAttributes: [:]
            )
        )
        pasteboard.setString("Q3 revenue", forType: .string)
        pasteboard.setData(rtfData, forType: .rtf)
        pasteboard.setData(Data("<b>Q3 revenue</b>".utf8), forType: .html)
        pasteboard.setData(try makePNGData(width: 4, height: 4), forType: .png)

        store.pollPasteboardForChanges()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(store.items.count, 1)
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.contentKind, .text)
        XCTAssertEqual(item.text, "Q3 revenue")
        XCTAssertEqual(item.rtfData, rtfData)
        XCTAssertNotNil(item.htmlData)
    }

    func testImageWithPlainTextOnlyStillGoesToTheImagePipeline() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }
        pasteboard.setString("caption", forType: .string)
        pasteboard.setData(try makePNGData(width: 4, height: 4), forType: .png)

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.first?.contentKind, .image)
        XCTAssertEqual(store.items.first?.text, "caption")
    }

    // MARK: Multi-file copies

    func testMultipleFinderFilesBecomeSeparateFileClips() async throws {
        let pasteboard = makePasteboard()
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil },
            clock: ClipboardStoreClock(now: { now }, sleep: { _ in })
        )
        defer { store.setMonitoringEnabled(false) }
        let directory = FileManager.default.temporaryDirectory
        let fileURLs = ["notes.txt", "photo.png", "slides.pdf"].map {
            directory.appendingPathComponent("CopyClipLite-\(UUID().uuidString)-\($0)")
        }
        pasteboard.setItemStrings(fileURLs.map(\.absoluteString), forType: .fileURL)
        pasteboard.setString("notes.txt\nphoto.png\nslides.pdf", forType: .string)

        store.pollPasteboardForChanges()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(store.items.count, 3)
        XCTAssertTrue(store.items.allSatisfy { $0.contentKind == .link })
        XCTAssertEqual(store.items.compactMap(\.linkURL?.path), fileURLs.map(\.path))
        XCTAssertTrue(store.items.allSatisfy { $0.createdAt == now && $0.lastCopiedAt == now })
        XCTAssertNil(store.captureWarning)
    }

    func testMultiFileCopyIsCappedWithAWarning() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }
        store.setHistoryLimit(200)
        let directory = FileManager.default.temporaryDirectory
        let fileURLs = (0..<55).map {
            directory.appendingPathComponent("CopyClipLite-\(UUID().uuidString)-\($0).txt")
        }
        pasteboard.setItemStrings(fileURLs.map(\.absoluteString), forType: .fileURL)

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.count, ClipboardCaptureReader.maximumCapturedFiles)
        XCTAssertEqual(store.items.first?.linkURL?.path, fileURLs[0].path)
        XCTAssertEqual(store.captureWarning, "Only the first 50 of 55 copied files were saved.")
    }

    // MARK: Import races

    func testThumbnailRepairDuringImportCannotOverwriteImportedHistory() async throws {
        let directory = try makeTemporaryDirectory()
        final class BlockingFault: @unchecked Sendable {
            let started = DispatchSemaphore(value: 0)
            let allowCompletion = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var shouldBlock = false
            var didBlock = false

            func visit(_ point: ClipboardStorageFaultPoint) {
                guard case .manifestWrite = point else { return }
                lock.lock()
                let block = shouldBlock && !didBlock
                if block {
                    didBlock = true
                }
                lock.unlock()
                guard block else { return }
                started.signal()
                allowCompletion.wait()
            }
        }

        let fault = BlockingFault()
        let storage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Store"),
            faultInjector: fault.visit
        )
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let importURL = directory.appendingPathComponent("import.json")
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 2, height: 2),
                    width: 2,
                    height: 2
                ),
                isPinned: true
            )
        ])
        sourceStorage.save([ClipboardItem(text: "imported")])
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let loaderGate = DispatchSemaphore(value: 0)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil },
            thumbnailLoader: { item in
                loaderGate.wait()
                return ClipboardThumbnailResult(
                    data: Data([1, 2, 3]),
                    fileName: item.image?.fileName ?? "repaired.png"
                )
            }
        )
        defer { store.setMonitoringEnabled(false) }
        let imageItem = try XCTUnwrap(store.items.first)
        XCTAssertNil(store.cachedThumbnailData(for: imageItem))

        let artifact = try await store.prepareImport(from: importURL)
        let plan = store.importPlan(for: artifact)
        fault.shouldBlock = true
        let importTask = Task {
            try await store.importHistory(plan: plan, strategy: .replace)
        }
        for _ in 0..<100 where !store.isTransferBusy {
            await Task.yield()
        }
        XCTAssertTrue(store.isTransferBusy)
        XCTAssertEqual(fault.started.wait(timeout: .now() + 2), .success)

        loaderGate.signal()
        try await Task.sleep(nanoseconds: 300_000_000)
        fault.allowCompletion.signal()
        _ = try await importTask.value
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(storage.load().map(\.text), ["imported"])
        XCTAssertEqual(store.items.map(\.text), ["imported"])
    }

    // MARK: Quit cleanup

    func testInterruptedQuitCleanupIsCompletedAtLaunch() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        defaults.set(true, forKey: "quitCleanupPending")
        storage.save([
            ClipboardItem(text: "pinned", isPinned: true),
            ClipboardItem(text: "unpinned"),
        ])
        _ = try storage.backup(storage.load(), reason: "pre-import")

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }

        XCTAssertEqual(store.items.map(\.text), ["pinned"])
        XCTAssertEqual(storage.load().map(\.text), ["pinned"])
        XCTAssertEqual(try storage.backupInventory(), .empty)
        XCTAssertEqual(store.backupInventory, .empty)
        XCTAssertTrue(defaults.bool(forKey: "quitCleanupPending"))
    }

    func testLaunchKeepsHistoryWhenPreviousQuitCleanupCompleted() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        storage.save([ClipboardItem(text: "pinned", isPinned: true), ClipboardItem(text: "unpinned")])

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }

        XCTAssertEqual(Set(store.items.map(\.text)), ["pinned", "unpinned"])
        XCTAssertTrue(defaults.bool(forKey: "quitCleanupPending"))
        XCTAssertTrue(store.clearUnpinnedHistoryOnQuitIfNeeded())
        XCTAssertNil(defaults.object(forKey: "quitCleanupPending"))
    }

    func testTogglingClearOnQuitSetsAndClearsPendingMarker() throws {
        let defaults = makeDefaults()
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }
        XCTAssertNil(defaults.object(forKey: "quitCleanupPending"))

        store.clearUnpinnedOnQuit = true
        XCTAssertTrue(defaults.bool(forKey: "quitCleanupPending"))

        store.clearUnpinnedOnQuit = false
        XCTAssertNil(defaults.object(forKey: "quitCleanupPending"))
    }

    func testFailedQuitCleanupKeepsPendingMarker() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        storage.save([ClipboardItem(text: "pinned", isPinned: true), ClipboardItem(text: "unpinned")])
        _ = try storage.backup(storage.load(), reason: "pre-import")
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: FailingBackupPurgeRepository(storage: storage),
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }

        XCTAssertFalse(store.clearUnpinnedHistoryOnQuitIfNeeded())
        XCTAssertTrue(defaults.bool(forKey: "quitCleanupPending"))

        XCTAssertFalse(
            ClipboardStore.clearUnpinnedHistoryOnQuitIfNeeded(
                storage: FailingBackupPurgeRepository(storage: storage),
                defaults: defaults
            )
        )
        XCTAssertTrue(defaults.bool(forKey: "quitCleanupPending"))

        XCTAssertTrue(ClipboardStore.clearUnpinnedHistoryOnQuitIfNeeded(storage: storage, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: "quitCleanupPending"))
    }

    // MARK: Transformations

    func testTransformedClipUsesInjectedClock() throws {
        let now = Date(timeIntervalSinceReferenceDate: 70_000)
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let earlier = now.addingTimeInterval(-60)
        storage.save([ClipboardItem(text: "hello world", createdAt: earlier, lastCopiedAt: earlier)])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil },
            pasteboardWriter: StubPasteboardWriter(result: .success),
            clock: ClipboardStoreClock(now: { now }, sleep: { _ in })
        )
        defer { store.setMonitoringEnabled(false) }
        let original = try XCTUnwrap(store.items.first)

        store.copyWithTransformation(original, transformation: .uppercase)

        let transformed = try XCTUnwrap(store.items.first)
        XCTAssertEqual(transformed.text, "HELLO WORLD")
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(transformed.createdAt, now)
        XCTAssertEqual(transformed.lastCopiedAt, now)
    }
}
