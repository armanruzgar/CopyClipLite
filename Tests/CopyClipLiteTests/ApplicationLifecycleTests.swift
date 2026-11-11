import XCTest
@testable import CopyClipLite

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()

        try super.tearDownWithError()
    }

    func testFirstRunShowsWelcomeWindowAndActivatesApplication() {
        let policy = CopyClipAppLaunchPolicy(hasCompletedWelcome: false)

        XCTAssertFalse(policy.suppressesInitialMainWindow)
        XCTAssertTrue(policy.activatesApplicationAfterLaunch)
    }

    func testReturningLaunchSuppressesInitialWindowAndStaysAccessoryOnly() {
        let policy = CopyClipAppLaunchPolicy(hasCompletedWelcome: true)

        XCTAssertTrue(policy.suppressesInitialMainWindow)
        XCTAssertFalse(policy.activatesApplicationAfterLaunch)
    }

    func testInitialWindowSuppressionIsConsumedOnlyOnce() {
        let delegate = makeDelegate(hasCompletedWelcome: true)

        XCTAssertTrue(delegate.consumeInitialWindowSuppression())
        XCTAssertFalse(delegate.consumeInitialWindowSuppression())
    }

    func testResigningActiveFlushesPendingStoreMutation() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "monitoringEnabled")
        storage.save([ClipboardItem(text: "pending deletion")])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil },
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )
        let item = try XCTUnwrap(store.items.first)
        store.togglePin(item)
        let delegate = makeDelegate(hasCompletedWelcome: true, store: store)

        delegate.applicationWillResignActive(
            Notification(name: NSApplication.didResignActiveNotification)
        )

        let flush = try XCTUnwrap(delegate.resignActiveFlush)
        let didFlush = await flush.value
        XCTAssertTrue(didFlush)
        XCTAssertEqual(storage.load().first?.isPinned, true)
    }

    func testTerminatingKeepsPinnedItemsAndRemovesUnpinnedHistory() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "monitoringEnabled")
        defaults.set(true, forKey: "clearUnpinnedOnQuit")
        storage.save([
            ClipboardItem(text: "pinned", isPinned: true),
            ClipboardItem(text: "unpinned"),
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: defaults,
            sourceApplicationProvider: { nil },
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )
        let delegate = makeDelegate(hasCompletedWelcome: true, store: store)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(store.items.map(\.text), ["pinned"])
        XCTAssertEqual(storage.load().map(\.text), ["pinned"])
    }

    func testStoreIsInjectedBeforeAnyViewLifecycleCallback() throws {
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil },
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )

        let delegate = makeDelegate(hasCompletedWelcome: true, store: store)

        XCTAssertTrue(delegate.store === store)
    }

    private func makeDelegate(
        hasCompletedWelcome: Bool,
        store: ClipboardStore? = nil
    ) -> AppDelegate {
        AppDelegate(
            store: store,
            hasCompletedWelcome: { hasCompletedWelcome },
            applyAccessoryActivationPolicy: {},
            activateApplication: {},
            cleanupWithoutStore: {}
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLiteLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makePasteboard() -> StubStorePasteboard {
        StubStorePasteboard()
    }
}
