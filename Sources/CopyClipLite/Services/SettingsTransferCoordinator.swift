import Foundation
import UniformTypeIdentifiers

@MainActor
final class SettingsTransferCoordinator: ObservableObject {
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var pendingImportPlan: ClipboardImportPlan?
    @Published var isConfirmingImport = false
    @Published private(set) var isTransferring = false
    @Published private(set) var isLoadingDroppedImport = false

    private var task: Task<Void, Never>?
    private var droppedLoadProgress: Progress?
    private var droppedLoadGeneration: UInt64 = 0
    /// Runs once a dropped file's provider callback has been handled, including a stale one that is ignored.
    var droppedLoadCallbackHandled: (@MainActor () -> Void)?

    func clearFeedback() {
        message = nil
        error = nil
    }

    func clearPendingImport() {
        pendingImportPlan = nil
        isConfirmingImport = false
    }

    func exportHistory(to url: URL, store: ClipboardStore) {
        guard beginTransfer(store: store) else { return }
        runTransfer(cancellationMessage: "Export cancelled.") { state in
            try await store.exportHistoryAsync(to: url)
            state.message = "Exported history to \(url.lastPathComponent)."
        }
    }

    func prepareImport(from url: URL, store: ClipboardStore) {
        guard beginTransfer(store: store) else { return }
        runTransfer(cancellationMessage: "Import cancelled.") { state in
            let artifact = try await store.prepareImport(from: url)
            try state.presentImport(artifact, store: store)
        }
    }

    func importHistory(strategy: ClipboardImportStrategy, store: ClipboardStore) {
        guard let plan = pendingImportPlan, beginTransfer(store: store) else { return }
        runTransfer(cancellationMessage: "Import cancelled before history was changed.") { state in
            let projection = plan.projection(for: strategy)
            let commit = try await store.importHistory(plan: plan, strategy: strategy)
            // Once the store commits, cancellation must not hide its successful result.
            state.message = "Imported \(commit.items.count) clips (\(projection.addedCount) added, "
                + "\(projection.deduplicatedCount) deduplicated, "
                + "\(projection.expiredCount) expired, "
                + "\(projection.overLimitCount) over limit, "
                + "\(projection.retainedPinnedCount) pinned). "
                + "Backup: \(commit.backupURL.lastPathComponent)"
        }
    }

    func loadDroppedImport(
        from provider: NSItemProvider,
        sourceFileName: String,
        store: ClipboardStore
    ) {
        guard beginTransfer(store: store) else { return }
        let generation = droppedLoadGeneration
        isLoadingDroppedImport = true
        droppedLoadProgress = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.json.identifier
        ) { [weak self, store] data, error in
            let loadErrorDescription = error?.localizedDescription
            Task { @MainActor [weak self, store, data, loadErrorDescription, sourceFileName] in
                guard let self else { return }
                defer { self.droppedLoadCallbackHandled?() }
                guard self.droppedLoadGeneration == generation else {
                    return
                }
                self.droppedLoadProgress = nil
                self.receiveDroppedImport(
                    data: data,
                    loadErrorDescription: loadErrorDescription,
                    sourceFileName: sourceFileName,
                    store: store
                )
            }
        }
    }

    func cancelCurrentTransfer() {
        guard isTransferring else { return }
        if let task {
            // Keep ownership until the task returns: an import may already be
            // committing, and another operation must not replace its task handle.
            task.cancel()
        } else {
            droppedLoadGeneration &+= 1
            droppedLoadProgress?.cancel()
            droppedLoadProgress = nil
            isLoadingDroppedImport = false
            isTransferring = false
            message = "Import cancelled."
        }
    }

    private func beginTransfer(store: ClipboardStore) -> Bool {
        guard !isTransferring, !store.isTransferBusy else { return false }
        clearFeedback()
        clearPendingImport()
        droppedLoadGeneration &+= 1
        isTransferring = true
        return true
    }

    private func runTransfer(
        cancellationMessage: String,
        operation: @escaping @MainActor (SettingsTransferCoordinator) async throws -> Void
    ) {
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                task = nil
                isTransferring = false
                isLoadingDroppedImport = false
            }
            do {
                try Task.checkCancellation()
                try await operation(self)
            } catch is CancellationError {
                clearPendingImport()
                message = cancellationMessage
            } catch {
                clearPendingImport()
                self.error = error.localizedDescription
            }
        }
    }

    private func presentImport(
        _ artifact: ClipboardImportArtifact,
        store: ClipboardStore
    ) throws {
        try Task.checkCancellation()
        pendingImportPlan = store.importPlan(for: artifact)
        isConfirmingImport = true
    }

    private func receiveDroppedImport(
        data: Data?,
        loadErrorDescription: String?,
        sourceFileName: String,
        store: ClipboardStore
    ) {
        if let loadErrorDescription {
            failDroppedImport(loadErrorDescription)
            return
        }
        guard let data else {
            failDroppedImport("The dropped history could not be read.")
            return
        }
        guard data.count <= ClipboardStorage.maximumImportBytes else {
            failDroppedImport(ClipboardStorageError.importTooLarge.localizedDescription)
            return
        }
        runTransfer(cancellationMessage: "Import cancelled.") { state in
            let artifact = try await store.prepareImport(data: data, sourceFileName: sourceFileName)
            try state.presentImport(artifact, store: store)
        }
    }

    private func failDroppedImport(_ message: String) {
        isTransferring = false
        isLoadingDroppedImport = false
        error = message
    }
}
