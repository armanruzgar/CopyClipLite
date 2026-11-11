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
        await delayedSaves.fireAndDrain(on: queue)

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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipboardPersistenceCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// Holds delayed saves so a test decides when their delay has elapsed.
final class DelayedSaves: @unchecked Sendable {
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

    /// Lets every pending delay elapse, then waits until whatever those saves did has landed:
    /// the queue runs them in order, and each one hands its completion to the main actor.
    func fireAndDrain(on queue: DispatchQueue) async {
        fire(on: queue)
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
        // The main actor runs jobs in the order they were enqueued, so this runs after the completions.
        await Task { @MainActor in }.value
    }
}
