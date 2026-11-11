import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
    func testPollingStoresSourceApplicationMetadata() throws {
        let pasteboard = makePasteboard()
        let sourceApplication = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Notes",
            name: "Notes"
        )
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { sourceApplication }
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("note text", forType: .string))

        store.pollPasteboardForChanges()

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.sourceApplication, sourceApplication)
        XCTAssertEqual(store.visibleItems(matching: "Notes").map(\.id), [item.id])
    }

    func testIgnoredSourceApplicationIsNotCaptured() throws {
        let pasteboard = makePasteboard()
        let sourceApplication = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Secret",
            name: "Secret"
        )
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { sourceApplication }
        )
        store.addIgnoredApplication(sourceApplication)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("private value", forType: .string))

        store.pollPasteboardForChanges()

        XCTAssertTrue(store.items.isEmpty)
    }

    func testVisibleItemsCanFilterByContentKindAndPinnedState() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let image = ClipboardImagePayload(data: Data([0, 1, 2, 3]), width: 12, height: 34)
        storage.save([
            ClipboardItem(text: "plain text"),
            ClipboardItem(text: "pinned text", isPinned: true),
            ClipboardItem(image: image),
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults()
        )

        XCTAssertEqual(
            store.visibleItems(matching: "", filter: .text).map(\.text).sorted(),
            [
                "pinned text",
                "plain text",
            ])
        XCTAssertEqual(store.visibleItems(matching: "", filter: .images).count, 1)
        XCTAssertEqual(
            store.visibleItems(matching: "", filter: .pinned).map(\.text), ["pinned text"])
    }

    func testPausedAndDisabledMonitoringRejectActivationTriggeredPolls() throws {
        for pause in [false, true] {
            let pasteboard = makePasteboard()
            let store = ClipboardStore(
                pasteboard: pasteboard,
                storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
                defaults: makeIsolatedDefaults(),
                sourceApplicationProvider: { nil }
            )
            if pause {
                store.pauseMonitoring(for: .fiveMinutes)
            } else {
                store.setMonitoringEnabled(false)
            }
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("must stay private", forType: .string))

            store.pollPasteboardForChanges(
                sourceApplicationOverride: ClipboardSourceApplication(
                    bundleIdentifier: "com.example.Source",
                    name: "Source"
                )
            )

            XCTAssertTrue(store.items.isEmpty)
        }
    }

    func testExpiredTimedPauseResumesMonitoringAfterRelaunch() throws {
        let base = Date(timeIntervalSinceReferenceDate: 20_000)
        let clock = ManualClipboardClock(now: base)
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "monitoringEnabled")
        defaults.set(base.addingTimeInterval(-60), forKey: "monitoringPausedUntil")

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults,
            clock: ClipboardStoreClock(
                now: { clock.now() },
                sleep: { try await clock.sleep(nanoseconds: $0) }
            )
        )

        XCTAssertTrue(store.isMonitoringEnabled)
        XCTAssertNil(store.monitoringPausedUntil)
        XCTAssertEqual(defaults.object(forKey: "monitoringEnabled") as? Bool, true)
        XCTAssertNil(defaults.object(forKey: "monitoringPausedUntil"))
    }

    func testFutureTimedPauseRelaunchResumesExactlyAtInjectedDeadline() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let clock = ManualClipboardClock(now: base)
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "monitoringEnabled")
        defaults.set(base.addingTimeInterval(60), forKey: "monitoringPausedUntil")
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults,
            clock: ClipboardStoreClock(
                now: { clock.now() },
                sleep: { try await clock.sleep(nanoseconds: $0) }
            )
        )

        XCTAssertFalse(store.isMonitoringEnabled)
        await fulfillment(of: [clock.expectSleepers()], timeout: 10)
        XCTAssertEqual(clock.waitingCount, 1)

        clock.advance(by: 59)
        // Still parked, so the resume task has nothing to run.
        XCTAssertEqual(clock.waitingCount, 1)
        XCTAssertFalse(store.isMonitoringEnabled)

        clock.advance(by: 1)
        await waitForState(of: store, "monitoring resumed") { store.isMonitoringEnabled }
        XCTAssertTrue(store.isMonitoringEnabled)
        XCTAssertNil(store.monitoringPausedUntil)
    }

    func testTimedPauseRecalculatesAfterWallClockMovesBackwardAndForward() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 40_000)
        let clock = ManualClipboardClock(now: base)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil },
            clock: ClipboardStoreClock(
                now: { clock.now() },
                sleep: { try await clock.sleep(nanoseconds: $0) }
            )
        )
        store.pauseMonitoring(for: .fiveMinutes)
        await fulfillment(of: [clock.expectSleepers()], timeout: 10)

        clock.setNow(base.addingTimeInterval(-3_600))
        clock.wakeAllSleepers()
        await fulfillment(of: [clock.expectSleepers()], timeout: 10)
        XCTAssertFalse(store.isMonitoringEnabled)
        XCTAssertEqual(clock.waitingCount, 1)

        clock.setNow(base.addingTimeInterval(301))
        clock.wakeAllSleepers()
        await waitForState(of: store, "monitoring resumed") { store.isMonitoringEnabled }
        XCTAssertTrue(store.isMonitoringEnabled)
    }

    func testManualPauseRemainsDisabledAfterRelaunch() throws {
        let clock = ManualClipboardClock(
            now: Date(timeIntervalSinceReferenceDate: 30_000)
        )
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "monitoringEnabled")

        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: defaults,
            clock: ClipboardStoreClock(
                now: { clock.now() },
                sleep: { try await clock.sleep(nanoseconds: $0) }
            )
        )

        XCTAssertFalse(store.isMonitoringEnabled)
        XCTAssertNil(store.monitoringPausedUntil)
    }

    func testClearUnpinnedOnQuitKeepsPinnedItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")

        let pinned = ClipboardItem(text: "pinned", isPinned: true)
        let unpinned = ClipboardItem(text: "unpinned")
        storage.save([pinned, unpinned])
        _ = try storage.backup(storage.load(), reason: "pre-import")
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults
        )
        store.clearUnpinnedHistoryOnQuitIfNeeded()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "pinned")
        XCTAssertEqual(try storage.backupInventory(), .empty)
    }

    func testQuitBackupPurgeFailureKeepsCompletedHistoryCleanup() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        storage.save([
            ClipboardItem(text: "pinned", isPinned: true),
            ClipboardItem(text: "unpinned"),
        ])
        _ = try storage.backup(storage.load(), reason: "pre-import")
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: FailingBackupPurgeRepository(storage: storage),
            defaults: defaults,
            sourceApplicationProvider: { nil }
        )

        XCTAssertFalse(store.clearUnpinnedHistoryOnQuitIfNeeded())

        XCTAssertEqual(store.items.map(\.text), ["pinned"])
        XCTAssertEqual(storage.load().map(\.text), ["pinned"])
        XCTAssertEqual(try storage.backupInventory().count, 1)
        XCTAssertTrue(store.storageErrorMessage?.contains("backups could not be deleted") == true)
    }

    func testClearUnpinnedOnQuitKeepsLiveCapturedPinnedImageFilesReadable() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        defaults.set(false, forKey: "keepPinnedOnClear")
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: defaults
        )
        let pngData = try makePNGData(width: 6, height: 6)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)
        let imageItem = try XCTUnwrap(store.items.first)
        store.togglePin(imageItem)

        store.clearUnpinnedHistoryOnQuitIfNeeded()

        let reloadedImage = try XCTUnwrap(storage.load().first)
        XCTAssertTrue(reloadedImage.isPinned)
        try assertReadableImageData(storage.imageData(for: reloadedImage))
        XCTAssertNotNil(storage.thumbnailData(for: reloadedImage))

        let reloadedPasteboard = makePasteboard()
        let reloadedStore = ClipboardStore(
            pasteboard: reloadedPasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        let reloadedStoreImage = try XCTUnwrap(reloadedStore.items.first)
        XCTAssertTrue(reloadedStoreImage.isPinned)
        XCTAssertTrue(reloadedStore.copy(reloadedStoreImage))
        try assertReadableImageData(reloadedPasteboard.data(forType: .png))
    }

    func testStaticClearOnQuitAlwaysKeepsPinnedItems() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        defaults.set(false, forKey: "keepPinnedOnClear")

        let pinned = ClipboardItem(text: "pinned", isPinned: true)
        let unpinned = ClipboardItem(text: "unpinned")
        storage.save([pinned, unpinned])
        _ = try storage.backup(storage.load(), reason: "pre-import")

        ClipboardStore.clearUnpinnedHistoryOnQuitIfNeeded(storage: storage, defaults: defaults)

        let remaining = storage.load()
        XCTAssertEqual(remaining.map(\.text), ["pinned"])
        XCTAssertEqual(try storage.backupInventory(), .empty)
    }

    func testStaticQuitPurgeFailureKeepsCompletedHistoryCleanup() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        storage.save([
            ClipboardItem(text: "pinned", isPinned: true),
            ClipboardItem(text: "unpinned"),
        ])
        _ = try storage.backup(storage.load(), reason: "pre-import")

        XCTAssertFalse(
            ClipboardStore.clearUnpinnedHistoryOnQuitIfNeeded(
                storage: FailingBackupPurgeRepository(storage: storage),
                defaults: defaults
            )
        )

        XCTAssertEqual(storage.load().map(\.text), ["pinned"])
        XCTAssertEqual(try storage.backupInventory().count, 1)
    }
}
