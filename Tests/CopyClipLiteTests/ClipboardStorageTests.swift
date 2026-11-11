import AppKit
import Foundation
import XCTest
@testable import CopyClipLite

private final class StorageOperationGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var enabled = false
    private var hasBlocked = false

    func enable() {
        lock.withLock { enabled = true }
    }

    func visit(_ point: ClipboardStorageFaultPoint) {
        guard point == .manifestWrite else { return }
        let shouldBlock = lock.withLock {
            guard enabled, !hasBlocked else { return false }
            hasBlocked = true
            return true
        }
        guard shouldBlock else { return }
        entered.signal()
        proceed.wait()
    }
}

private final class StorageOperationResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.withLock { self.result = result }
    }

    func get() -> Result<Value, Error>? {
        lock.withLock { result }
    }
}

final class ClipboardStorageTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        try super.tearDownWithError()

        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testStorageUsesPrivatePermissions() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)

        storage.save([ClipboardItem(text: "private value")])

        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: storage.imageDirectoryURL), 0o700)
        XCTAssertEqual(try permissions(at: storage.fileURL), 0o600)
    }

    func testInvalidHistoryIsBackedUpBeforeReturningEmptyHistory() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        try "not json".write(to: storage.fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(storage.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.fileURL.path))

        let backupFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("Recovery-invalid-") }

        XCTAssertEqual(backupFiles.count, 1)
        let recoveryURL = directory.appendingPathComponent(try XCTUnwrap(backupFiles.first))
        XCTAssertEqual(try permissions(at: recoveryURL), 0o700)
        XCTAssertEqual(
            try permissions(at: recoveryURL.appendingPathComponent("clipboard-history.json")),
            0o600
        )
    }

    func testLegacyTextOnlyItemsDecodeAsText() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let legacyJSON = """
        [{"id":"00000000-0000-0000-0000-000000000001","text":"legacy clip"}]
        """
        try legacyJSON.write(to: storage.fileURL, atomically: true, encoding: .utf8)

        let loadedItem = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(loadedItem.contentKind, .text)
        XCTAssertEqual(loadedItem.text, "legacy clip")
        XCTAssertEqual(loadedItem.previewText, "legacy clip")

        let reloadedItem = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(reloadedItem, loadedItem)
        let normalizedHistory = try String(contentsOf: storage.fileURL, encoding: .utf8)
        for requiredKey in [
            "contentKind",
            "createdAt",
            "lastCopiedAt",
            "isPinned",
            "copyCount",
        ] {
            XCTAssertTrue(normalizedHistory.contains("\"\(requiredKey)\""))
        }
    }

    func testUnreadableHistoryCannotBeOverwrittenByAnEmptyFallback() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let image = ClipboardImagePayload(
            data: try makePNGData(width: 2, height: 2),
            width: 2,
            height: 2
        )
        try storage.saveValidated([
            ClipboardItem(text: "preserve me"),
            ClipboardItem(image: image),
        ])
        let originalManifest = try Data(contentsOf: storage.fileURL)
        let originalSidecars = Set(
            try FileManager.default.contentsOfDirectory(atPath: storage.imageDirectoryURL.path)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: storage.fileURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storage.fileURL.path
            )
        }

        guard case .failure(.unreadableHistory) = storage.loadResult() else {
            return XCTFail("Expected unreadable history to protect the committed files")
        }
        XCTAssertThrowsError(try storage.saveValidated([]))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storage.fileURL.path
        )
        XCTAssertEqual(try Data(contentsOf: storage.fileURL), originalManifest)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: storage.imageDirectoryURL.path)),
            originalSidecars
        )
    }

    func testDuplicateLocalIdentifiersAreQuarantinedBeforeStoreReconciliation() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        let duplicateID = UUID()
        let data = try JSONEncoder().encode([
            ClipboardItem(id: duplicateID, text: "first"),
            ClipboardItem(id: duplicateID, text: "second"),
        ])
        try data.write(to: storage.fileURL, options: .atomic)

        guard case let .failure(.invalidHistory(backupFileName)) = storage.loadResult() else {
            return XCTFail("Expected duplicate identifiers to be treated as invalid history")
        }

        XCTAssertNotNil(backupFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.fileURL.path))
        XCTAssertThrowsError(
            try storage.saveValidated([
                ClipboardItem(id: duplicateID, text: "first"),
                ClipboardItem(id: duplicateID, text: "second"),
            ])
        )
    }

    func testCopyCountIsBoundedAndHistoryIncrementsSaturate() throws {
        var item = ClipboardItem(text: "bounded", copyCount: Int.max)
        XCTAssertEqual(item.copyCount, ClipboardItem.maximumCopyCount)

        item.copyCount += 1
        XCTAssertEqual(item.copyCount, ClipboardItem.maximumCopyCount)

        let recorded = ClipboardHistoryRules.recordingText(
            "bounded",
            rtfData: nil,
            htmlData: nil,
            sourceApplication: nil,
            capturedAt: Date(),
            in: [item]
        )
        XCTAssertEqual(recorded.first?.copyCount, ClipboardItem.maximumCopyCount)

        let negativeCountJSON = Data(
            #"{"text":"negative","contentKind":"text","copyCount":-5}"#.utf8
        )
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: negativeCountJSON)
        XCTAssertEqual(decoded.copyCount, 1)
    }

    func testImageItemsRoundTripThroughStorage() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = try makePNGData(width: 2, height: 2)
        let thumbnailData = Data([9, 8, 7])
        let image = ClipboardImagePayload(
            data: imageData,
            thumbnailData: thumbnailData,
            width: 12,
            height: 34,
            contentHash: "hash"
        )

        storage.save([ClipboardItem(image: image)])

        let loadedItem = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(loadedItem.contentKind, .image)
        XCTAssertNil(loadedItem.image?.data)
        XCTAssertEqual(storage.imageData(for: loadedItem), imageData)
        let repairedThumbnail = try XCTUnwrap(storage.thumbnailData(for: loadedItem))
        XCTAssertTrue(ClipboardImageProcessor.isDecodableImage(repairedThumbnail))
        XCTAssertNotNil(loadedItem.image?.fileName)
        XCTAssertNotNil(loadedItem.image?.thumbnailFileName)
        XCTAssertEqual(loadedItem.previewText, "Image")

        let historyText = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertFalse(historyText.contains(imageData.base64EncodedString()))
        XCTAssertFalse(historyText.contains(thumbnailData.base64EncodedString()))
    }

    func testLegacyInlineImageItemsMigrateToImageFilesOnLoad() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = Data([0, 1, 2, 3])
        let thumbnailData = Data([9, 8, 7])
        let legacyJSON = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "contentKind":"image",
          "image":{
            "data":"\(imageData.base64EncodedString())",
            "thumbnailData":"\(thumbnailData.base64EncodedString())",
            "width":12,
            "height":34
          }
        }]
        """
        try legacyJSON.write(to: storage.fileURL, atomically: true, encoding: .utf8)

        let loadedItem = try XCTUnwrap(storage.load().first)

        XCTAssertNil(loadedItem.image?.data)
        XCTAssertEqual(storage.imageData(for: loadedItem), imageData)
        XCTAssertEqual(storage.thumbnailData(for: loadedItem), thumbnailData)
        XCTAssertEqual(loadedItem.image?.byteCount, imageData.count)

        let migratedHistoryText = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertFalse(migratedHistoryText.contains(imageData.base64EncodedString()))
        XCTAssertFalse(migratedHistoryText.contains(thumbnailData.base64EncodedString()))
    }

    func testExportEmbedsExternalizedImageData() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        let exportURL = directory.appendingPathComponent("export.json")
        let imageData = try makePNGData(width: 3, height: 4)
        let thumbnailData = try makePNGData(width: 2, height: 2)
        let image = ClipboardImagePayload(
            data: imageData,
            thumbnailData: thumbnailData,
            width: 12,
            height: 34,
            contentHash: "hash"
        )
        storage.save([ClipboardItem(image: image)])
        let loadedItems = storage.load()

        try storage.export(loadedItems, to: exportURL)

        let exportText = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertFalse(exportText.contains(try XCTUnwrap(loadedItems.first?.image?.fileName)))
        XCTAssertFalse(exportText.contains(try XCTUnwrap(loadedItems.first?.image?.thumbnailFileName)))

        let importedItem = try XCTUnwrap(storage.importItems(from: exportURL).first)
        XCTAssertNotNil(importedItem.image?.data)
        XCTAssertNotNil(importedItem.image?.thumbnailData)
        XCTAssertEqual(importedItem.image?.width, 3)
        XCTAssertEqual(importedItem.image?.height, 4)
        XCTAssertNotNil(importedItem.image?.contentHash)
        XCTAssertNil(importedItem.image?.fileName)
        XCTAssertNil(importedItem.image?.thumbnailFileName)
    }

    func testExportWaitsForConcurrentStorageMutationWhileImportProceeds() throws {
        let directory = try makeTemporaryDirectory()
        let gate = StorageOperationGate()
        let storage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Store"),
            faultInjector: gate.visit
        )
        _ = storage.loadResult()
        let item = ClipboardItem(
            image: ClipboardImagePayload(
                data: try makePNGData(width: 3, height: 3),
                width: 3,
                height: 3
            )
        )
        try storage.saveValidated([item])
        let loadedItems = storage.load()
        let sourceStorage = ClipboardStorage(
            appDirectory: directory.appendingPathComponent("Source")
        )
        sourceStorage.save([ClipboardItem(text: "imported")])
        let importURL = directory.appendingPathComponent("import.json")
        try sourceStorage.export(sourceStorage.load(), to: importURL)
        let exportURL = directory.appendingPathComponent("export.json")
        let saveFinished = DispatchSemaphore(value: 0)
        let exportFinished = DispatchSemaphore(value: 0)
        let importFinished = DispatchSemaphore(value: 0)
        let exportResult = StorageOperationResult<Void>()
        let importResult = StorageOperationResult<[ClipboardItem]>()

        gate.enable()
        DispatchQueue.global().async {
            _ = try? storage.saveValidated(loadedItems)
            saveFinished.signal()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            exportResult.store(Result { try storage.export(loadedItems, to: exportURL) })
            exportFinished.signal()
        }
        DispatchQueue.global().async {
            importResult.store(Result { try storage.importItems(from: importURL) })
            importFinished.signal()
        }

        // Exporting reads the image sidecars, so it has to wait for a save that may be
        // pruning them.
        XCTAssertEqual(exportFinished.wait(timeout: .now() + 0.05), .timedOut)
        // Importing only reads a caller-supplied file and decodes it, so it must not be
        // held up by an in-flight save. Making it wait deadlocks an import that is
        // started while a persist is still pending.
        XCTAssertEqual(importFinished.wait(timeout: .now() + 2), .success)
        gate.proceed.signal()

        XCTAssertEqual(saveFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(exportFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNoThrow(try exportResult.get()?.get())
        XCTAssertEqual(try importResult.get()?.get().map(\.text), ["imported"])
    }

    func testImportRejectsExternalImagePathsBeforeTheyReachStorageWrites() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let importURL = directory.appendingPathComponent("malicious.json")
        let escapedURL = directory.appendingPathComponent("escaped.png")
        let imageData = Data([0, 1, 2, 3])
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "text":"",
          "contentKind":"image",
          "image":{
            "data":"\(imageData.base64EncodedString())",
            "fileName":"../../escaped.png",
            "width":1,
            "height":1,
            "byteCount":4
          }
        }]
        """
        try json.write(to: importURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: importURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("external image paths are not allowed")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))
    }

    func testSavingPrunedHistoryRemovesOrphanedImageFiles() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let image = ClipboardImagePayload(
            data: Data([0, 1, 2, 3]),
            thumbnailData: Data([9, 8, 7]),
            width: 1,
            height: 1
        )
        storage.save([ClipboardItem(image: image)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.imageDirectoryURL.path).count, 2)

        try storage.saveValidated([])

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.imageDirectoryURL.path).isEmpty)
    }

    func testFailedManifestCommitPreservesPreviousImageGeneration() throws {
        final class FaultSwitch {
            var failManifestWrite = false
        }

        let faultSwitch = FaultSwitch()
        let storage = ClipboardStorage(
            appDirectory: try makeTemporaryDirectory(),
            faultInjector: { point in
                if case .manifestWrite = point, faultSwitch.failManifestWrite {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )
        let itemID = UUID()
        let oldData = Data([0, 1, 2, 3])
        let newData = Data([9, 8, 7, 6])
        try storage.saveValidated([
            ClipboardItem(
                id: itemID,
                image: ClipboardImagePayload(data: oldData, width: 1, height: 1)
            )
        ])
        let oldItem = try XCTUnwrap(storage.load().first)
        let oldFileName = try XCTUnwrap(oldItem.image?.fileName)
        faultSwitch.failManifestWrite = true

        XCTAssertThrowsError(
            try storage.saveValidated([
                ClipboardItem(
                    id: itemID,
                    image: ClipboardImagePayload(data: newData, width: 1, height: 1)
                )
            ])
        )

        let stillCommittedItem = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(stillCommittedItem.image?.fileName, oldFileName)
        XCTAssertEqual(storage.imageData(for: stillCommittedItem), oldData)

        faultSwitch.failManifestWrite = false
        try storage.saveValidated([stillCommittedItem])

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: storage.imageDirectoryURL.path),
            [oldFileName]
        )
    }

    func testEverySidecarAndManifestStagingFailurePreservesCommittedGeneration() throws {
        final class FaultController {
            var point: ClipboardStorageFaultPoint?
            var occurrence = 0
            var visits = 0

            func visit(_ visitedPoint: ClipboardStorageFaultPoint) throws {
                guard visitedPoint == point else { return }
                visits += 1
                if visits == occurrence {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }

        let scenarios: [(ClipboardStorageFaultPoint, Int)] = [
            (.imageWrite, 1),
            (.imageWriteCompleted, 1),
            (.imageWrite, 2),
            (.imageWriteCompleted, 2),
            (.manifestWrite, 1),
            (.manifestWriteCompleted, 1),
        ]

        for (point, occurrence) in scenarios {
            let controller = FaultController()
            let storage = ClipboardStorage(
                appDirectory: try makeTemporaryDirectory(),
                faultInjector: controller.visit
            )
            let itemID = UUID()
            let oldFull = try makePNGData(width: 2, height: 2)
            let oldThumbnail = try makePNGData(width: 1, height: 1)
            let newFull = try makePNGData(width: 3, height: 3)
            let newThumbnail = try makePNGData(width: 2, height: 1)
            try storage.saveValidated([
                ClipboardItem(
                    id: itemID,
                    image: ClipboardImagePayload(
                        data: oldFull,
                        thumbnailData: oldThumbnail,
                        width: 2,
                        height: 2
                    )
                )
            ])
            let committedManifest = try Data(contentsOf: storage.fileURL)
            let committedSidecars = Set(
                try FileManager.default.contentsOfDirectory(
                    atPath: storage.imageDirectoryURL.path
                )
            )

            controller.point = point
            controller.occurrence = occurrence
            controller.visits = 0
            XCTAssertThrowsError(
                try storage.saveValidated([
                    ClipboardItem(
                        id: itemID,
                        image: ClipboardImagePayload(
                            data: newFull,
                            thumbnailData: newThumbnail,
                            width: 3,
                            height: 3
                        )
                    )
                ]),
                "Expected \(point), occurrence \(occurrence), to abort the save"
            )

            XCTAssertEqual(try Data(contentsOf: storage.fileURL), committedManifest)
            XCTAssertEqual(
                Set(try FileManager.default.contentsOfDirectory(
                    atPath: storage.imageDirectoryURL.path
                )),
                committedSidecars
            )
            let stillCommitted = try XCTUnwrap(storage.load().first)
            XCTAssertEqual(storage.imageData(for: stillCommitted), oldFull)
            XCTAssertEqual(storage.thumbnailData(for: stillCommitted), oldThumbnail)

            controller.point = nil
            let recovered = try storage.saveValidated([
                ClipboardItem(
                    id: itemID,
                    image: ClipboardImagePayload(
                        data: newFull,
                        thumbnailData: newThumbnail,
                        width: 3,
                        height: 3
                    )
                )
            ])
            let referencedFiles = Set(
                [
                    recovered.first?.image?.fileName,
                    recovered.first?.image?.thumbnailFileName,
                ].compactMap { $0 }
            )
            XCTAssertEqual(
                Set(try FileManager.default.contentsOfDirectory(
                    atPath: storage.imageDirectoryURL.path
                )),
                referencedFiles
            )
        }
    }

    func testImportAcceptsPortableImageRecords() throws {
        let directory = try makeTemporaryDirectory()
        let sourceStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Source"))
        let destinationStorage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Destination"))
        let exportURL = directory.appendingPathComponent("portable.json")
        let imageData = try makePNGData(width: 1, height: 1)
        sourceStorage.save([
            ClipboardItem(image: ClipboardImagePayload(data: imageData, width: 1, height: 1))
        ])
        try sourceStorage.export(sourceStorage.load(), to: exportURL)

        let imported = try destinationStorage.importItems(from: exportURL)
        try destinationStorage.saveValidated(imported)

        XCTAssertEqual(destinationStorage.load().count, 1)
        XCTAssertNotNil(destinationStorage.imageData(for: destinationStorage.load()[0]))
    }

    func testImportRejectsUndecodableImageData() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let importURL = directory.appendingPathComponent("invalid-image.json")
        let invalidData = Data([1, 2, 3])
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "text":"",
          "contentKind":"image",
          "image":{
            "data":"\(invalidData.base64EncodedString())",
            "width":1,
            "height":1,
            "byteCount":3
          },
          "copyCount":1
        }]
        """
        try json.write(to: importURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: importURL)) { error in
            guard let storageError = error as? ClipboardStorageError,
                  case .invalidImportedItem = storageError else {
                XCTFail("Expected invalid imported image, got \(error)")
                return
            }
        }
    }

    func testCurrentTransferRejectsUnknownContentKindBeforeNormalization() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let importURL = directory.appendingPathComponent("unknown-kind.json")
        let json = """
        {
          "format":"CopyClipLite",
          "version":1,
          "items":[{
            "id":"00000000-0000-0000-0000-000000000001",
            "text":"value",
            "contentKind":"future-kind",
            "createdAt":0,
            "lastCopiedAt":0,
            "isPinned":false,
            "copyCount":1
          }]
        }
        """
        try json.write(to: importURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: importURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("unknown content kind “future-kind”")
            )
        }
    }

    func testCurrentTransferRejectsBlankTextAndNegativeImageDimensions() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let blankURL = directory.appendingPathComponent("blank.json")
        let blankJSON = """
        {
          "format":"CopyClipLite",
          "version":1,
          "items":[{
            "id":"00000000-0000-0000-0000-000000000001",
            "text":"   ",
            "contentKind":"text",
            "createdAt":0,
            "lastCopiedAt":0,
            "isPinned":false,
            "copyCount":1
          }]
        }
        """
        try blankJSON.write(to: blankURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try storage.importItems(from: blankURL))

        let imageURL = directory.appendingPathComponent("negative-dimensions.json")
        let imageData = try makePNGData(width: 1, height: 1)
        let imageJSON = """
        {
          "format":"CopyClipLite",
          "version":1,
          "items":[{
            "id":"00000000-0000-0000-0000-000000000001",
            "text":"",
            "contentKind":"image",
            "createdAt":0,
            "lastCopiedAt":0,
            "isPinned":false,
            "copyCount":1,
            "image":{
              "data":"\(imageData.base64EncodedString())",
              "width":-1,
              "height":1,
              "byteCount":\(imageData.count),
              "contentHash":"\(ClipboardImageProcessor.contentHash(for: imageData))"
            }
          }]
        }
        """
        try imageJSON.write(to: imageURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try storage.importItems(from: imageURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("image dimensions must be positive")
            )
        }
    }

    func testCurrentTransferRejectsMissingRequiredFieldsAndMismatchedImageMetadata() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let missingIDURL = directory.appendingPathComponent("missing-id.json")
        try """
        {
          "format":"CopyClipLite",
          "version":1,
          "items":[{
            "text":"value",
            "contentKind":"text",
            "createdAt":0,
            "lastCopiedAt":0,
            "isPinned":false,
            "copyCount":1
          }]
        }
        """.write(to: missingIDURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: missingIDURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("the clip identifier is missing")
            )
        }

        let imageData = try makePNGData(width: 1, height: 1)
        let wrongHashURL = directory.appendingPathComponent("wrong-hash.json")
        try """
        {
          "format":"CopyClipLite",
          "version":1,
          "items":[{
            "id":"00000000-0000-0000-0000-000000000001",
            "text":"",
            "contentKind":"image",
            "createdAt":0,
            "lastCopiedAt":0,
            "isPinned":false,
            "copyCount":1,
            "image":{
              "data":"\(imageData.base64EncodedString())",
              "width":1,
              "height":1,
              "byteCount":\(imageData.count),
              "contentHash":"wrong"
            }
          }]
        }
        """.write(to: wrongHashURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: wrongHashURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("image content hash does not match its data")
            )
        }
    }

    func testMalformedCurrentTransferEnvelopeReturnsSpecificErrors() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())

        XCTAssertThrowsError(
            try storage.importItems(
                data: Data(
                    """
                    {"format":"CopyClipLite","version":1,"items":"not-an-array"}
                    """.utf8
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("the transfer items field is missing or malformed")
            )
        }

        XCTAssertThrowsError(
            try storage.importItems(
                data: Data(
                    """
                    {"format":"CopyClipLite","version":"one","items":[]}
                    """.utf8
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem("the transfer version is missing or invalid")
            )
        }

        XCTAssertThrowsError(
            try storage.importItems(
                data: Data(
                    """
                    {
                      "format":"CopyClipLite",
                      "version":1,
                      "items":[{
                        "id":"not-a-uuid",
                        "text":"value",
                        "contentKind":"text",
                        "createdAt":0,
                        "lastCopiedAt":0,
                        "isPinned":false,
                        "copyCount":1
                      }]
                    }
                    """.utf8
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .invalidImportedItem(
                    "the current transfer field “items[0].id” is malformed"
                )
            )
        }
    }

    func testCurrentTransferRejectsDuplicateClipIdentifiers() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let duplicateID = "00000000-0000-0000-0000-000000000001"

        XCTAssertThrowsError(
            try storage.importItems(
                data: Data(
                    """
                    {
                      "format":"CopyClipLite",
                      "version":1,
                      "items":[
                        {
                          "id":"\(duplicateID)",
                          "text":"first",
                          "contentKind":"text",
                          "createdAt":0,
                          "lastCopiedAt":0,
                          "isPinned":false,
                          "copyCount":1
                        },
                        {
                          "id":"\(duplicateID)",
                          "text":"second",
                          "contentKind":"text",
                          "createdAt":1,
                          "lastCopiedAt":1,
                          "isPinned":false,
                          "copyCount":1
                        }
                      ]
                    }
                    """.utf8
                )
            )
        ) { error in
            XCTAssertEqual(error as? ClipboardStorageError, .duplicateImportedItem)
        }
    }

    func testValidLegacyRawArrayImportMigratesExplicitDefaults() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imported = try storage.importItems(
            data: Data(
                """
                [{"text":"legacy raw-array clip"}]
                """.utf8
            )
        )

        let item = try XCTUnwrap(imported.first)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(item.text, "legacy raw-array clip")
        XCTAssertEqual(item.contentKind, .text)
        XCTAssertEqual(item.copyCount, 1)
        XCTAssertFalse(item.isPinned)
        XCTAssertEqual(item.createdAt, item.lastCopiedAt)
    }

    func testUnsupportedTransferVersionIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let importURL = directory.appendingPathComponent("future.json")
        try """
        {"format":"CopyClipLite","version":99,"items":[]}
        """.write(to: importURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try storage.importItems(from: importURL)) { error in
            XCTAssertEqual(error as? ClipboardStorageError, .unsupportedTransferVersion(99))
        }
    }

    func testExportDataCanBeValidatedDirectlyForDroppedImport() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let exportURL = directory.appendingPathComponent("drop.json")
        storage.save([ClipboardItem(text: "dropped")])
        try storage.export(storage.load(), to: exportURL)

        let imported = try storage.importItems(data: Data(contentsOf: exportURL))

        XCTAssertEqual(imported.map(\.text), ["dropped"])
    }

    func testExportPreflightsSameVersionItemLimitBeforeWriting() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let exportURL = directory.appendingPathComponent("too-many.json")
        let items = (0...ClipboardStorage.maximumImportedItems).map {
            ClipboardItem(text: "clip-\($0)", isPinned: true)
        }

        XCTAssertThrowsError(try storage.export(items, to: exportURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .incompatibleExport(
                    "1,001 clips exceeds the 1,000-clip export limit. "
                        + "Unpin or delete clips, then export again."
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
    }

    func testInternalBackupDoesNotInheritPublicTransferItemLimit() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let items = (0...ClipboardStorage.maximumImportedItems).map { index in
            ClipboardItem(text: "pinned-\(index)", isPinned: true)
        }

        let backupURL = try storage.backup(items, reason: "large-history")

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try permissions(at: backupURL), 0o600)
        let document = try JSONDecoder().decode(
            ClipboardTransferDocument.self,
            from: Data(contentsOf: backupURL)
        )
        XCTAssertEqual(document.items.count, items.count)
    }

    func testPreImportBackupsAreCappedAtFiveMostRecentFiles() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        var createdURLs: [URL] = []

        for index in 0..<7 {
            let url = try storage.backup(
                [ClipboardItem(text: "backup-\(index)")],
                reason: "pre-import"
            )
            createdURLs.append(url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }

        let inventory = try storage.backupInventory()
        XCTAssertEqual(inventory.count, 5)
        XCTAssertEqual(
            Set(inventory.urls.map(\.lastPathComponent)),
            Set(createdURLs.suffix(5).map(\.lastPathComponent))
        )
        XCTAssertGreaterThan(inventory.totalByteCount, 0)
    }

    func testRecoveryDirectoriesAreCappedAtTwoMostRecentBackups() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        var recoveryURLs: [URL] = []

        for index in 0..<7 {
            try Data("broken-\(index)".utf8).write(to: storage.fileURL)
            guard case let .failure(.invalidHistory(backupFileName)) = storage.loadResult() else {
                return XCTFail("Expected invalid history to be quarantined")
            }
            let recoveryURL = directory.appendingPathComponent(try XCTUnwrap(backupFileName))
            recoveryURLs.append(recoveryURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: recoveryURL.path
            )
        }

        let inventory = try storage.backupInventory()
        XCTAssertEqual(inventory.count, 2)
        XCTAssertEqual(
            Set(inventory.urls.map(\.lastPathComponent)),
            Set(recoveryURLs.suffix(2).map(\.lastPathComponent))
        )
    }

    func testBackupInventoryCountsBothKindsAndPurgeLeavesUnrelatedFiles() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        let unrelatedURL = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelatedURL)
        _ = try storage.backup([ClipboardItem(text: "before import")], reason: "pre-import")
        try Data("broken history".utf8).write(to: storage.fileURL)
        guard case .failure(.invalidHistory) = storage.loadResult() else {
            return XCTFail("Expected invalid history to create a recovery backup")
        }

        let inventory = try storage.backupInventory()
        XCTAssertEqual(inventory.count, 2)
        XCTAssertGreaterThan(inventory.totalByteCount, 0)

        try storage.purgeBackups()

        XCTAssertEqual(try storage.backupInventory(), .empty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testNearLimitImageExportRoundTripsAndFirstAggregateOverflowPreservesDestination() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let exportURL = directory.appendingPathComponent("near-limit-images.json")
        let image = try NearLimitImageFixture.canonicalPNG()
        let imageData = try XCTUnwrap(image.data)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertGreaterThanOrEqual(
            imageData.count,
            ClipboardStorage.maximumImportedImageBytes * 8 / 10
        )
        XCTAssertLessThanOrEqual(
            imageData.count,
            ClipboardStorage.maximumImportedImageBytes
        )

        func items(count: Int) -> [ClipboardItem] {
            (1...count).map { index in
                ClipboardItem(
                    id: UUID(
                        uuid: (
                            0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0,
                            UInt8(index >> 8),
                            UInt8(truncatingIfNeeded: index)
                        )
                    ),
                    text: "near-limit image \(index)",
                    image: image,
                    createdAt: fixedDate,
                    lastCopiedAt: fixedDate,
                    isPinned: index.isMultiple(of: 2),
                    copyCount: index
                )
            }
        }

        let maximumCompatibleItems = items(count: 7)
        try storage.export(maximumCompatibleItems, to: exportURL)
        let exportedData = try Data(contentsOf: exportURL)
        XCTAssertLessThanOrEqual(exportedData.count, ClipboardStorage.maximumImportBytes)

        let importedItems = try storage.importItems(data: exportedData)
        XCTAssertEqual(importedItems, maximumCompatibleItems)
        XCTAssertTrue(importedItems.allSatisfy { $0.image == image })

        let overflowURL = directory.appendingPathComponent("aggregate-overflow.json")
        let sentinel = Data("existing export must survive".utf8)
        let formattedMaximumImportBytes = ByteCountFormatter.string(
            fromByteCount: Int64(ClipboardStorage.maximumImportBytes),
            countStyle: .file
        )
        try sentinel.write(to: overflowURL)

        XCTAssertThrowsError(try storage.export(items(count: 8), to: overflowURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .incompatibleExport(
                    "the encoded file would exceed \(formattedMaximumImportBytes)"
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: overflowURL), sentinel)
    }

    func testExportRejectsCorruptStoredImageBeforeWriting() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let exportURL = directory.appendingPathComponent("corrupt-image.json")
        let corruptItem = ClipboardItem(
            image: ClipboardImagePayload(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                width: 1,
                height: 1
            )
        )

        XCTAssertThrowsError(try storage.export([corruptItem], to: exportURL)) { error in
            XCTAssertEqual(
                error as? ClipboardStorageError,
                .incompatibleExport("an image clip is not a valid canonical PNG")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
    }

    func testExportRejectsNonLosslessFutureTimestampsBeforeWriting() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let exportURL = directory.appendingPathComponent("future-timestamp.json")
        let future = Date().addingTimeInterval(10 * 60)

        XCTAssertThrowsError(
            try storage.export(
                [
                    ClipboardItem(
                        text: "future",
                        createdAt: future,
                        lastCopiedAt: future
                    )
                ],
                to: exportURL
            )
        ) { error in
            guard case let .incompatibleExport(reason) = error as? ClipboardStorageError else {
                XCTFail("Expected incompatible export, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("timestamps"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
    }

    func testInvalidHistoryQuarantinesImageSidecarsWithManifest() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 2, height: 2),
                    width: 2,
                    height: 2
                )
            )
        ])
        let sidecars = try FileManager.default.contentsOfDirectory(
            atPath: storage.imageDirectoryURL.path
        )
        XCTAssertFalse(sidecars.isEmpty)
        try "broken".write(to: storage.fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(storage.load().isEmpty)

        let recoveryName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: directory.path)
                .first { $0.hasPrefix("Recovery-invalid-") }
        )
        let recoveredImagesURL = directory
            .appendingPathComponent(recoveryName)
            .appendingPathComponent("Images", isDirectory: true)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: recoveredImagesURL.path)),
            Set(sidecars)
        )

        storage.save([ClipboardItem(text: "new")])
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: recoveredImagesURL.path)),
            Set(sidecars)
        )
    }

    func testMissingThumbnailSelfRepairsFromFullImage() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 4, height: 3),
                    width: 4,
                    height: 3
                )
            )
        ])
        let initiallyLoaded = try XCTUnwrap(storage.load().first)
        let thumbnailName = try XCTUnwrap(initiallyLoaded.image?.thumbnailFileName)
        try FileManager.default.removeItem(
            at: storage.imageDirectoryURL.appendingPathComponent(thumbnailName)
        )

        let repairedItem = try XCTUnwrap(storage.load().first)
        let repairedData = try XCTUnwrap(storage.thumbnailData(for: repairedItem))

        XCTAssertTrue(ClipboardImageProcessor.isDecodableImage(repairedData))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storage.imageDirectoryURL
                    .appendingPathComponent(try XCTUnwrap(repairedItem.image?.thumbnailFileName))
                    .path
            )
        )
    }

    func testLegacyFileBackedImageHashIsBackfilledAndPersisted() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        let imageData = try makePNGData(width: 2, height: 2)
        let fileName = "legacy.png"
        try imageData.write(to: storage.imageDirectoryURL.appendingPathComponent(fileName))
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "text":"",
          "contentKind":"image",
          "image":{
            "fileName":"\(fileName)",
            "width":2,
            "height":2,
            "byteCount":\(imageData.count)
          },
          "copyCount":1
        }]
        """
        try json.write(to: storage.fileURL, atomically: true, encoding: .utf8)

        let item = try XCTUnwrap(storage.load().first)
        let canonicalHash = try XCTUnwrap(
            ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: imageData, isPNG: true)
            ).contentHash
        )

        XCTAssertEqual(item.image?.contentHash, canonicalHash)
        XCTAssertTrue(
            try String(contentsOf: storage.fileURL, encoding: .utf8)
                .contains(canonicalHash)
        )
    }

    func testExportNamesImageClipWithMissingSidecarAndBackupSkipsIt() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let exportURL = directory.appendingPathComponent("missing-sidecar.json")
        let brokenID = UUID()
        let intactID = UUID()
        storage.save([
            ClipboardItem(text: "plain text"),
            ClipboardItem(
                id: brokenID,
                text: "Holiday photo",
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 3, height: 2),
                    width: 3,
                    height: 2
                )
            ),
            ClipboardItem(
                id: intactID,
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 2, height: 2),
                    width: 2,
                    height: 2
                )
            ),
        ])
        let stored = storage.load()
        let brokenFileName = try XCTUnwrap(
            stored.first { $0.id == brokenID }?.image?.fileName
        )
        try FileManager.default.removeItem(
            at: storage.imageDirectoryURL.appendingPathComponent(brokenFileName)
        )

        XCTAssertThrowsError(try storage.export(stored, to: exportURL)) { error in
            guard case let .incompatibleExport(reason) = error as? ClipboardStorageError else {
                return XCTFail("Expected incompatible export, got \(error)")
            }
            XCTAssertTrue(reason.hasPrefix("1 image clip is missing its image data"), reason)
            XCTAssertTrue(reason.contains("Holiday photo"), reason)
            XCTAssertTrue(reason.contains("3 x 2"), reason)
            XCTAssertTrue(reason.contains("last copied"), reason)
            XCTAssertTrue(reason.contains("Delete it from the history"), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))

        let backupURL = try storage.backup(stored, reason: "pre-import")
        let document = try JSONDecoder().decode(
            ClipboardTransferDocument.self,
            from: Data(contentsOf: backupURL)
        )
        XCTAssertEqual(
            Set(document.items.compactMap(\.id)),
            Set(stored.map(\.id)).subtracting([brokenID])
        )
        XCTAssertTrue(document.items.contains { $0.id == intactID })
    }

    func testExportFailsEarlyWithSizeGuidanceWhenHistoryExceedsTransferLimit() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let exportURL = directory.appendingPathComponent("too-large.json")
        let html = Data(count: ClipboardStorage.maximumImportedRichTextBytes)
        let items = (0..<12).map { index in
            ClipboardItem(text: "rich \(index)", htmlData: html)
        }

        XCTAssertThrowsError(try storage.export(items, to: exportURL)) { error in
            guard case let .incompatibleExport(reason) = error as? ClipboardStorageError else {
                return XCTFail("Expected incompatible export, got \(error)")
            }
            let limit = ByteCountFormatter.string(
                fromByteCount: Int64(ClipboardStorage.maximumImportBytes),
                countStyle: .file
            )
            XCTAssertTrue(reason.hasPrefix("the history is at least "), reason)
            XCTAssertTrue(reason.contains("more than the \(limit) export limit"), reason)
            XCTAssertTrue(reason.contains("Delete or unpin large image clips"), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLiteTests-\(UUID().uuidString)", isDirectory: true)
        tempDirectories.append(directory)
        return directory
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as? Int ?? -1
    }

    private func makePNGData(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
