import Foundation
import XCTest

@testable import CopyClipLite

final class ClipboardPersistenceCoordinatorTests: XCTestCase {
    func testScheduledSaveCoalescesToLatestSnapshot() async throws {
        let storage = ClipboardStorage(appDirectory: try temporaryDirectory())
        _ = storage.loadResult()
        let queue = DispatchQueue(label: "ClipboardPersistenceCoordinatorTests")
        let delayedSaves = DelayedSaves()
        let coordinator = ClipboardPersistenceCoordinator(
            storage: storage,
            queue: queue,
            scheduleDelayedSave: { delayedSaves.append($0) }
        )
        let saved = expectation(description: "latest save completed")

        coordinator.scheduleSave([ClipboardItem(text: "old")]) { _ in
            XCTFail("Cancelled generation must not complete")
        }
        coordinator.scheduleSave([ClipboardItem(text: "latest")]) { result in
            if case .failure(let error) = result {
                XCTFail("Latest save failed: \(error)")
            }
            saved.fulfill()
        }
        XCTAssertEqual(delayedSaves.count, 2)

        // Both delays elapse; the superseded save runs first if it runs at all.
        delayedSaves.fire(on: queue)
        await fulfillment(of: [saved], timeout: 10)
        XCTAssertEqual(storage.load().map(\.text), ["latest"])
    }

    func testFlushInvalidatesDelayedSave() async throws {
        let storage = ClipboardStorage(appDirectory: try temporaryDirectory())
        _ = storage.loadResult()
        let queue = DispatchQueue(label: "ClipboardPersistenceCoordinatorTests")
        let delayedSaves = DelayedSaves()
        let coordinator = ClipboardPersistenceCoordinator(
            storage: storage,
            queue: queue,
            scheduleDelayedSave: { delayedSaves.append($0) }
        )
        coordinator.scheduleSave([ClipboardItem(text: "delayed")]) { _ in
            XCTFail("Invalidated delayed save must not complete")
        }

        let flushed = try await coordinator.flush([ClipboardItem(text: "flushed")])
        delayedSaves.fire(on: queue)
        // Drain the queue, then the main actor, where the delayed save's completion would be queued.
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        await MainActor.run {}

        XCTAssertEqual(flushed.map(\.text), ["flushed"])
        XCTAssertEqual(storage.load().map(\.text), ["flushed"])
    }

    func testImportCommitCreatesBackupAndLoadsCommittedCandidate() async throws {
        let storage = ClipboardStorage(appDirectory: try temporaryDirectory())
        _ = storage.loadResult()
        let current = [ClipboardItem(text: "current")]
        try storage.saveValidated(current)
        let coordinator = ClipboardPersistenceCoordinator(storage: storage)
        let candidate = [ClipboardItem(text: "imported")]

        let commit = try await coordinator.commitImport(
            currentItems: current,
            candidateItems: candidate
        )

        XCTAssertEqual(commit.items, candidate)
        XCTAssertEqual(storage.load(), candidate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: commit.backupURL.path))
    }

    /// Holds delayed saves so a test decides when their delay has elapsed.
    private final class DelayedSaves: @unchecked Sendable {
        private let lock = NSLock()
        private var workItems: [DispatchWorkItem] = []

        var count: Int {
            lock.withLock { workItems.count }
        }

        func append(_ workItem: DispatchWorkItem) {
            lock.withLock { workItems.append(workItem) }
        }

        func fire(on queue: DispatchQueue) {
            let due = lock.withLock {
                defer { workItems.removeAll() }
                return workItems
            }
            due.forEach { queue.async(execute: $0) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardPersistenceCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
