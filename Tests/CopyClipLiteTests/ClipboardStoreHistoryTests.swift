import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
    func testInitializationPrunesExpiredUnpinnedItemsButKeepsPinnedItems() throws {
        let now = Date()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(text: "expired", lastCopiedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)),
            ClipboardItem(
                text: "pinned", lastCopiedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
                isPinned: true),
            ClipboardItem(text: "recent", lastCopiedAt: now.addingTimeInterval(-60)),
        ])

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults()
        )

        XCTAssertEqual(Set(store.items.map(\.text)), ["pinned", "recent"])
    }

    func testHistoryLimitTrimsOnlyUnpinnedItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let now = Date()
        let clips = (0..<12).map { index in
            ClipboardItem(
                text: "clip-\(index)", lastCopiedAt: now.addingTimeInterval(TimeInterval(-index)))
        }
        storage.save(
            clips + [
                ClipboardItem(
                    text: "pinned", lastCopiedAt: now.addingTimeInterval(-1_000), isPinned: true)
            ])

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults()
        )

        store.setHistoryLimit(10)

        XCTAssertEqual(store.items.filter { !$0.isPinned }.count, 10)
        XCTAssertTrue(store.items.contains { $0.text == "pinned" })
    }

    func testProspectiveHistoryLimitDeletionCountDoesNotMutateHistory() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let now = Date()
        storage.save(
            (0..<12).map { index in
                let timestamp = now.addingTimeInterval(TimeInterval(-index))
                return ClipboardItem(
                    text: "clip-\(index)",
                    createdAt: timestamp,
                    lastCopiedAt: timestamp
                )
            }
        )
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        let originalItems = store.items

        XCTAssertEqual(store.prospectiveDeletionCount(historyLimit: 10), 2)
        XCTAssertEqual(store.prospectiveDeletionCount(historyLimit: 200), 0)
        XCTAssertEqual(store.items, originalItems)
        XCTAssertEqual(store.historyLimit, 50)
    }

    func testProspectiveRetentionDeletionCountMatchesAppliedPolicy() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldDate = now.addingTimeInterval(-2 * 24 * 60 * 60)
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(text: "old", createdAt: oldDate, lastCopiedAt: oldDate),
            ClipboardItem(
                text: "old pinned",
                createdAt: oldDate,
                lastCopiedAt: oldDate,
                isPinned: true
            ),
            ClipboardItem(text: "recent", createdAt: now, lastCopiedAt: now),
        ])
        let defaults = makeIsolatedDefaults()
        defaults.set(ClipboardRetentionPolicy.never.rawValue, forKey: "retentionPolicy")
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults,
            clock: ClipboardStoreClock(now: { now }, sleep: { _ in })
        )
        let originalItems = store.items

        XCTAssertEqual(
            store.prospectiveDeletionCount(retentionPolicy: .oneDay, now: now),
            1
        )
        XCTAssertEqual(store.items, originalItems)

        store.setRetentionPolicy(.oneDay)

        XCTAssertEqual(Set(store.items.map(\.text)), ["old pinned", "recent"])
        XCTAssertEqual(defaults.string(forKey: "retentionPolicy"), "oneDay")
    }

    func testTogglePinDoesNotTrimJustUnpinnedItem() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let now = Date()
        let clips = (0..<10).map { index in
            ClipboardItem(
                text: "clip-\(index)", lastCopiedAt: now.addingTimeInterval(TimeInterval(-index)))
        }
        storage.save(
            clips + [
                ClipboardItem(text: "pinned", lastCopiedAt: now, isPinned: true)
            ])

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        store.setHistoryLimit(10)

        guard let pinnedItem = store.items.first(where: { $0.text == "pinned" }) else {
            XCTFail("Pinned item should exist")
            return
        }

        store.togglePin(pinnedItem)

        XCTAssertTrue(store.items.contains { $0.text == "pinned" })
    }

    func testRequiredPasteboardWriteFailureDoesNotMutateHistory() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "hello")])
        let writer = StubPasteboardWriter(result: .failure)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            pasteboardWriter: writer
        )
        let item = try XCTUnwrap(store.items.first)

        XCTAssertFalse(store.copy(item))
        XCTAssertEqual(store.items.first?.copyCount, 1)
        XCTAssertEqual(writer.requests.count, 1)
        XCTAssertNotNil(store.storageErrorMessage)
    }

    func testRequiredPasteboardRepresentationFailureMatrixDoesNotMutateHistory() throws {
        do {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            storage.save([ClipboardItem(text: "plain")])
            let writer = SelectiveFailurePasteboardWriter(
                failingTypes: [NSPasteboard.PasteboardType.string.rawValue]
            )
            let store = ClipboardStore(
                pasteboard: makePasteboard(),
                storage: storage,
                defaults: makeIsolatedDefaults(),
                pasteboardWriter: writer
            )
            let item = try XCTUnwrap(store.items.first)

            XCTAssertFalse(store.copy(item))
            XCTAssertEqual(store.items, [item])
            XCTAssertEqual(
                writer.requests.first?.required.map(\.type),
                [NSPasteboard.PasteboardType.string.rawValue]
            )
            XCTAssertNotNil(store.storageErrorMessage)
        }

        do {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            storage.save([ClipboardItem(text: "mixed case")])
            let writer = SelectiveFailurePasteboardWriter(
                failingTypes: [NSPasteboard.PasteboardType.string.rawValue]
            )
            let store = ClipboardStore(
                pasteboard: makePasteboard(),
                storage: storage,
                defaults: makeIsolatedDefaults(),
                pasteboardWriter: writer
            )
            let itemsBeforeCopy = store.items

            store.copyWithTransformation(
                try XCTUnwrap(store.items.first),
                transformation: .uppercase
            )

            XCTAssertEqual(store.items, itemsBeforeCopy)
            XCTAssertEqual(
                writer.requests.first?.required,
                [
                    ClipboardPasteboardRepresentation(
                        .string,
                        value: .string("MIXED CASE")
                    )
                ]
            )
            XCTAssertNotNil(store.storageErrorMessage)
        }

        do {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            storage.save([
                ClipboardItem(
                    image: ClipboardImagePayload(
                        data: try makePNGData(width: 2, height: 2),
                        width: 2,
                        height: 2
                    )
                )
            ])
            let writer = SelectiveFailurePasteboardWriter(
                failingTypes: [NSPasteboard.PasteboardType.png.rawValue]
            )
            let store = ClipboardStore(
                pasteboard: makePasteboard(),
                storage: storage,
                defaults: makeIsolatedDefaults(),
                pasteboardWriter: writer
            )
            let item = try XCTUnwrap(store.items.first)

            XCTAssertFalse(store.copy(item))
            XCTAssertEqual(store.items, [item])
            XCTAssertEqual(
                writer.requests.first?.required.map(\.type),
                [NSPasteboard.PasteboardType.png.rawValue]
            )
            XCTAssertNotNil(store.storageErrorMessage)
        }
    }

    func testSuccessfulCopyClearsOnlyTheResolvedPasteboardWriteWarning() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                text: "rich",
                rtfData: Data("rtf".utf8)
            )
        ])
        let writer = StubPasteboardWriter(
            result: .degraded(optionalTypes: [NSPasteboard.PasteboardType.rtf.rawValue])
        )
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            pasteboardWriter: writer
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(String(repeating: "x", count: 20_001), forType: .string))
        store.pollPasteboardForChanges()
        let independentCaptureWarning = try XCTUnwrap(store.captureWarning)
        let item = try XCTUnwrap(store.items.first)

        XCTAssertTrue(store.copy(item))
        XCTAssertNotNil(store.pasteboardWriteWarning)
        XCTAssertEqual(store.captureWarning, independentCaptureWarning)

        writer.result = .success
        XCTAssertTrue(store.copy(item))

        XCTAssertNil(store.pasteboardWriteWarning)
        XCTAssertEqual(store.captureWarning, independentCaptureWarning)
    }

    func testManualClearRemovesPinnedAndUnpinnedItemsWhenRetentionIsDisabled() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "keepPinnedOnClear")
        storage.save([
            ClipboardItem(text: "pinned", isPinned: true),
            ClipboardItem(text: "unpinned"),
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )

        await store.clearHistory()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(storage.load().isEmpty)
    }

    func testManualClearPurgesClipboardBackups() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "clear me")])
        _ = try storage.backup(storage.load(), reason: "pre-import")
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        XCTAssertEqual(store.backupInventory.count, 1)

        await store.clearHistory()

        XCTAssertTrue(storage.load().isEmpty)
        XCTAssertEqual(store.backupInventory, .empty)
        XCTAssertEqual(try storage.backupInventory(), .empty)
    }

    func testDeleteBackupsUpdatesVisibleInventoryWithoutClearingHistory() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "keep me")])
        _ = try storage.backup(storage.load(), reason: "pre-import")
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        XCTAssertEqual(store.backupLocation, storage.fileURL.deletingLastPathComponent())

        store.deleteBackups()

        XCTAssertEqual(store.items.map(\.text), ["keep me"])
        XCTAssertEqual(store.backupInventory, .empty)
        XCTAssertEqual(try storage.backupInventory(), .empty)
    }

    func testBackupPurgeFailureDoesNotUndoManualClearAndSurfacesError() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "clear me")])
        _ = try storage.backup(storage.load(), reason: "pre-import")
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "keepPinnedOnClear")
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: FailingBackupPurgeRepository(storage: storage),
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )

        await store.clearHistory()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(storage.load().isEmpty)
        XCTAssertEqual(try storage.backupInventory().count, 1)
        XCTAssertTrue(store.storageErrorMessage?.contains("backups could not be deleted") == true)
    }

    func testUnpinningAtHistoryLimitTrimsExcessItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let now = Date()
        let clips = (0..<10).map { index in
            ClipboardItem(
                text: "clip-\(index)", lastCopiedAt: now.addingTimeInterval(TimeInterval(-index)))
        }
        let pinnedClip = ClipboardItem(text: "pinned", lastCopiedAt: now, isPinned: true)
        storage.save(clips + [pinnedClip])

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        store.setHistoryLimit(10)

        XCTAssertEqual(store.items.filter { !$0.isPinned }.count, 10)

        store.togglePin(pinnedClip)

        XCTAssertEqual(store.items.filter { !$0.isPinned }.count, 10)
        XCTAssertTrue(store.items.contains { $0.text == "pinned" && !$0.isPinned })
    }

    func testPinningBeyondTransferLimitWarnsAndUnpinAllRecovers() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let pinnedItems = (0..<ClipboardStorage.maximumImportedItems).map { index in
            ClipboardItem(text: "pinned-\(index)", isPinned: true)
        }
        let itemToPin = ClipboardItem(text: "pin me")
        storage.save(pinnedItems + [itemToPin])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )

        store.togglePin(try XCTUnwrap(store.items.first(where: { $0.id == itemToPin.id })))

        XCTAssertEqual(store.items.count, 1_001)
        XCTAssertEqual(
            store.captureWarning,
            "History cannot be exported: 1,001 clips exceeds the 1,000-clip export limit. "
                + "Unpin or delete clips, then export again."
        )
        XCTAssertEqual(store.prospectiveUnpinAllDeletionCount(), 951)

        store.unpinAll()

        XCTAssertEqual(store.items.count, 50)
        XCTAssertTrue(store.items.allSatisfy { !$0.isPinned })
        XCTAssertNil(store.captureWarning)
    }

    func testSuccessfulTransformedCopyClearsOnlyItsStorageIssue() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "recover me")])
        let writer = StubPasteboardWriter(result: .failure)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            pasteboardWriter: writer
        )
        let item = try XCTUnwrap(store.items.first)
        let pasteController = makePasteControllerWithPermissionError(
            item: item,
            store: store
        )
        let independentPasteIssue = try XCTUnwrap(pasteController.lastError)

        store.copyWithTransformation(item, transformation: .uppercase)
        XCTAssertNotNil(store.storageErrorMessage)

        writer.result = .success
        store.copyWithTransformation(item, transformation: .uppercase)

        XCTAssertNil(store.storageErrorMessage)
        XCTAssertEqual(pasteController.lastError, independentPasteIssue)
        XCTAssertEqual(store.items.first?.text, "RECOVER ME")
    }

    func testReCopyPlainTextClearsStaleRichTextData() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let rtfData = "{\\rtf1\\ansi Hello}".data(using: .utf8)!
        let htmlData = "<b>Hello</b>".data(using: .utf8)!
        storage.save([
            ClipboardItem(text: "Hello", rtfData: rtfData, htmlData: htmlData)
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults()
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Hello", forType: .string))

        store.pollPasteboardForChanges()

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.text, "Hello")
        XCTAssertNil(item.rtfData)
        XCTAssertNil(item.htmlData)
        XCTAssertFalse(item.hasRichText)
    }

    func testBulkPinUnpinAndDeleteApplyToExactSelection() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let first = ClipboardItem(text: "first")
        let second = ClipboardItem(text: "second")
        let untouched = ClipboardItem(text: "untouched")
        storage.save([first, second, untouched])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        let selectedIDs: Set<ClipboardItem.ID> = [first.id, second.id]

        store.setPinned(true, ids: selectedIDs)
        XCTAssertTrue(
            store.items.filter { selectedIDs.contains($0.id) }.allSatisfy(\.isPinned)
        )
        XCTAssertFalse(try XCTUnwrap(store.items.first { $0.id == untouched.id }).isPinned)

        store.setPinned(false, ids: [first.id])
        XCTAssertFalse(try XCTUnwrap(store.items.first { $0.id == first.id }).isPinned)
        XCTAssertTrue(try XCTUnwrap(store.items.first { $0.id == second.id }).isPinned)

        let didDeleteSelection = await store.delete(ids: selectedIDs)
        XCTAssertTrue(didDeleteSelection)
        XCTAssertEqual(store.items.map(\.id), [untouched.id])
        XCTAssertEqual(storage.load().map(\.id), [untouched.id])
    }

    func testDeleteUpdatesMemoryBeforeOffMainPersistenceCompletes() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let item = ClipboardItem(text: "delete without blocking UI")
        storage.save([item])
        let repository = BlockingSaveRepository(storage: storage)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: repository,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        repository.blockNextSave()

        let deletion = Task { await store.delete(item) }
        await fulfillment(of: [repository.saveBlockedExpectation], timeout: 10)

        XCTAssertTrue(repository.isSaveBlocked)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(storage.load().map(\.id), [item.id])

        repository.allowSave()
        let didDelete = await deletion.value
        XCTAssertTrue(didDelete)
        XCTAssertTrue(storage.load().isEmpty)
    }
}

struct FailingBackupPurgeRepository: ClipboardStoreRepository {
    let storage: ClipboardStorage

    var fileURL: URL { storage.fileURL }
    var imageCleanupPending: Bool { storage.imageCleanupPending }

    func loadResult() -> Result<[ClipboardItem], ClipboardStorageError> {
        storage.loadResult()
    }

    func saveValidated(_ items: [ClipboardItem]) throws -> [ClipboardItem] {
        try storage.saveValidated(items)
    }

    func backup(_ items: [ClipboardItem], reason: String) throws -> URL {
        try storage.backup(items, reason: reason)
    }

    func backupInventory() throws -> ClipboardBackupInventory {
        try storage.backupInventory()
    }

    func purgeBackups() throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    func export(_ items: [ClipboardItem], to url: URL) throws {
        try storage.export(items, to: url)
    }

    func importItems(from url: URL) throws -> [ClipboardItem] {
        try storage.importItems(from: url)
    }

    func importItems(data: Data) throws -> [ClipboardItem] {
        try storage.importItems(data: data)
    }

    func imageData(for item: ClipboardItem) -> Data? {
        storage.imageData(for: item)
    }

    func thumbnailDataRepairingIfNeeded(for item: ClipboardItem) -> ClipboardThumbnailResult? {
        storage.thumbnailDataRepairingIfNeeded(for: item)
    }
}

private final class BlockingSaveRepository: ClipboardStoreRepository, @unchecked Sendable {
    let storage: ClipboardStorage
    var imageCleanupPending: Bool { storage.imageCleanupPending }
    private let lock = NSLock()
    private let proceed = DispatchSemaphore(value: 0)
    private var shouldBlock = false
    private var saveBlocked = false
    let saveBlockedExpectation = XCTestExpectation(description: "save blocked")

    init(storage: ClipboardStorage) {
        self.storage = storage
    }

    var fileURL: URL { storage.fileURL }

    var isSaveBlocked: Bool {
        lock.withLock { saveBlocked }
    }

    func blockNextSave() {
        lock.withLock { shouldBlock = true }
    }

    func allowSave() {
        proceed.signal()
    }

    func loadResult() -> Result<[ClipboardItem], ClipboardStorageError> {
        storage.loadResult()
    }

    func saveValidated(_ items: [ClipboardItem]) throws -> [ClipboardItem] {
        let block = lock.withLock {
            guard shouldBlock else { return false }
            shouldBlock = false
            saveBlocked = true
            return true
        }
        if block {
            saveBlockedExpectation.fulfill()
            proceed.wait()
            lock.withLock { saveBlocked = false }
        }
        return try storage.saveValidated(items)
    }

    func backup(_ items: [ClipboardItem], reason: String) throws -> URL {
        try storage.backup(items, reason: reason)
    }

    func backupInventory() throws -> ClipboardBackupInventory {
        try storage.backupInventory()
    }

    func purgeBackups() throws {
        try storage.purgeBackups()
    }

    func export(_ items: [ClipboardItem], to url: URL) throws {
        try storage.export(items, to: url)
    }

    func importItems(from url: URL) throws -> [ClipboardItem] {
        try storage.importItems(from: url)
    }

    func importItems(data: Data) throws -> [ClipboardItem] {
        try storage.importItems(data: data)
    }

    func imageData(for item: ClipboardItem) -> Data? {
        storage.imageData(for: item)
    }

    func thumbnailDataRepairingIfNeeded(for item: ClipboardItem) -> ClipboardThumbnailResult? {
        storage.thumbnailDataRepairingIfNeeded(for: item)
    }
}
