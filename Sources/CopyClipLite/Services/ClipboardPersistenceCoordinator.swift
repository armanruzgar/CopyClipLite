import Foundation

private final class PersistenceGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == generation
    }
}

private final class ImportCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
    }
}

final class ClipboardPersistenceCoordinator: @unchecked Sendable {
    private let storage: any ClipboardHistoryRepository
    private let queue: DispatchQueue
    private let generation = PersistenceGeneration()
    private let workItemLock = NSLock()
    private var scheduledWorkItem: DispatchWorkItem?

    init(
        storage: any ClipboardHistoryRepository,
        queue: DispatchQueue = DispatchQueue(label: "CopyClipLite.persistence", qos: .utility)
    ) {
        self.storage = storage
        self.queue = queue
    }

    deinit {
        invalidateScheduledSave()
    }

    func scheduleSave(
        _ snapshot: [ClipboardItem],
        completion: @escaping @MainActor @Sendable (Result<[ClipboardItem], Error>) -> Void
    ) {
        cancelScheduledWorkItem()
        let currentGeneration = generation.advance()
        let storage = storage
        let generation = generation
        let workItem = DispatchWorkItem {
            guard generation.isCurrent(currentGeneration) else { return }
            let result = Result { try storage.saveValidated(snapshot) }
            Task { @MainActor in
                guard generation.isCurrent(currentGeneration) else { return }
                completion(result)
            }
        }
        setScheduledWorkItem(workItem)
        queue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func flush(_ snapshot: [ClipboardItem]) async throws -> [ClipboardItem] {
        invalidateScheduledSave()
        let storage = storage
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try storage.saveValidated(snapshot) })
            }
        }
    }

    func flushSynchronously(_ snapshot: [ClipboardItem]) throws -> [ClipboardItem] {
        invalidateScheduledSave()
        return try queue.sync { try storage.saveValidated(snapshot) }
    }

    func invalidateScheduledSave() {
        cancelScheduledWorkItem()
        _ = generation.advance()
    }

    func commitImport(
        currentItems: [ClipboardItem],
        candidateItems: [ClipboardItem]
    ) async throws -> ClipboardImportCommit {
        let cancellationState = ImportCancellationState()
        let storage = storage

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellationState.checkCancellation()
                        try storage.saveValidated(currentItems)
                        let backupURL = try storage.backup(currentItems, reason: "pre-import")
                        try cancellationState.checkCancellation()
                        try storage.saveValidated(candidateItems)
                        let loadedItems = try storage.loadResult().get().sorted {
                            $0.lastCopiedAt > $1.lastCopiedAt
                        }
                        // A save scheduled during the commit holds pre-import items.
                        self.invalidateScheduledSave()
                        continuation.resume(
                            returning: ClipboardImportCommit(
                                backupURL: backupURL,
                                items: loadedItems
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellationState.cancel()
        }
    }

    private func cancelScheduledWorkItem() {
        workItemLock.lock()
        let workItem = scheduledWorkItem
        scheduledWorkItem = nil
        workItemLock.unlock()
        workItem?.cancel()
    }

    private func setScheduledWorkItem(_ workItem: DispatchWorkItem) {
        workItemLock.lock()
        scheduledWorkItem = workItem
        workItemLock.unlock()
    }
}
