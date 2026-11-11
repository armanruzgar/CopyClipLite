import Foundation
import XCTest
@testable import CopyClipLite

final class ClipboardRichTextStorageTests: XCTestCase {
    private var tempDirectories: [URL] = []

    private let rtf = Data(#"{\rtf1\ansi {\b bold} sidecar}"#.utf8)
    private let html = Data("<p><b>bold</b> sidecar</p>".utf8)

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        for directory in tempDirectories {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.appendingPathComponent("RichText").path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testRichTextRoundTripsThroughSidecarFiles() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let item = ClipboardItem(text: "bold sidecar", rtfData: rtf, htmlData: html)

        let persisted = try storage.saveValidated([item])

        XCTAssertEqual(persisted, [item])
        XCTAssertEqual(storage.load(), [item])
        XCTAssertEqual(try permissions(at: storage.richTextDirectoryURL), 0o700)
        let files = try richTextFiles(storage)
        XCTAssertEqual(
            files,
            [
                "\(item.id.uuidString)-\(ClipboardImageProcessor.contentHash(for: rtf)).rtf",
                "\(item.id.uuidString)-\(ClipboardImageProcessor.contentHash(for: html)).html",
            ].sorted()
        )
        for file in files {
            XCTAssertEqual(
                try permissions(at: storage.richTextDirectoryURL.appendingPathComponent(file)),
                0o600
            )
        }
    }

    func testManifestReferencesRichTextByFileNameInsteadOfEmbeddingBytes() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        try storage.saveValidated([
            ClipboardItem(text: "bold sidecar", rtfData: rtf, htmlData: html)
        ])

        let manifest = try manifestRecords(storage)
        let record = try XCTUnwrap(manifest.first)
        XCTAssertNil(record["rtfData"])
        XCTAssertNil(record["htmlData"])
        XCTAssertNotNil(record["rtfFileName"] as? String)
        XCTAssertNotNil(record["htmlFileName"] as? String)
        let manifestText = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertFalse(manifestText.contains(rtf.base64EncodedString()))
        XCTAssertFalse(manifestText.contains(html.base64EncodedString()))
    }

    func testUnchangedRichTextFilesAreNotRewrittenOnLaterSaves() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let item = ClipboardItem(text: "bold sidecar", rtfData: rtf, htmlData: html)
        try storage.saveValidated([item])
        let identifiers = try fileNumbers(storage)

        try storage.saveValidated([ClipboardItem(text: "newer"), item])
        XCTAssertEqual(try fileNumbers(storage), identifiers)

        let reloadedStorage = ClipboardStorage(appDirectory: storage.fileURL.deletingLastPathComponent())
        let loaded = reloadedStorage.load()
        try reloadedStorage.saveValidated(loaded + [ClipboardItem(text: "after relaunch")])
        XCTAssertEqual(try fileNumbers(storage), identifiers)
    }

    func testChangedRichTextReplacesItsSidecar() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        var item = ClipboardItem(text: "edited", rtfData: rtf)
        try storage.saveValidated([item])
        item.rtfData = Data(#"{\rtf1 changed}"#.utf8)

        try storage.saveValidated([item])

        XCTAssertEqual(
            try richTextFiles(storage),
            ["\(item.id.uuidString)-\(ClipboardImageProcessor.contentHash(for: item.rtfData!)).rtf"]
        )
        XCTAssertEqual(storage.load(), [item])
    }

    func testLegacyInlineRichTextMigratesToSidecarsOnLoad() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        try writeLegacyManifest(to: storage)

        let loaded = try XCTUnwrap(storage.loadResult().get().first)

        XCTAssertEqual(loaded.rtfData, rtf)
        XCTAssertEqual(loaded.htmlData, html)
        XCTAssertEqual(try richTextFiles(storage).count, 2)
        let manifestText = try String(contentsOf: storage.fileURL, encoding: .utf8)
        XCTAssertFalse(manifestText.contains(rtf.base64EncodedString()))
        XCTAssertFalse(manifestText.contains(html.base64EncodedString()))
        XCTAssertEqual(storage.load(), [loaded])
    }

    func testFailedLegacyMigrationRemovesNewRichTextFilesAndKeepsManifest() throws {
        let scenarios: [(ClipboardStorageFaultPoint, Int)] = [
            (.richTextWrite, 2),
            (.richTextWriteCompleted, 1),
            (.richTextWriteCompleted, 2),
            (.manifestWrite, 1),
            (.manifestWriteCompleted, 1),
        ]
        for (point, occurrence) in scenarios {
            let fault = FaultCounter(point: point, occurrence: occurrence)
            let storage = ClipboardStorage(
                appDirectory: try makeTemporaryDirectory(),
                faultInjector: fault.visit
            )
            try writeLegacyManifest(to: storage)
            let legacyManifest = try Data(contentsOf: storage.fileURL)

            guard case .failure(.persistenceFailed) = storage.loadResult() else {
                XCTFail("Expected \(point) #\(occurrence) to fail the migration")
                continue
            }
            XCTAssertEqual(try Data(contentsOf: storage.fileURL), legacyManifest)
            XCTAssertEqual(try richTextFiles(storage), [], "\(point) #\(occurrence)")
            XCTAssertThrowsError(try storage.saveValidated([]))
        }
    }

    func testFailedSaveKeepsPreviouslyCommittedRichText() throws {
        let fault = FaultCounter(point: .manifestWrite, occurrence: 0)
        let storage = ClipboardStorage(
            appDirectory: try makeTemporaryDirectory(),
            faultInjector: fault.visit
        )
        let item = ClipboardItem(text: "committed", rtfData: rtf)
        try storage.saveValidated([item])
        let committedFiles = try richTextFiles(storage)
        fault.occurrence = 1

        XCTAssertThrowsError(
            try storage.saveValidated([ClipboardItem(text: "new", htmlData: html)])
        )

        XCTAssertEqual(try richTextFiles(storage), committedFiles)
        XCTAssertEqual(storage.load(), [item])
    }

    func testUnreferencedRichTextFilesAreRemoved() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        try storage.saveValidated([ClipboardItem(text: "gone soon", rtfData: rtf, htmlData: html)])
        XCTAssertEqual(try richTextFiles(storage).count, 2)

        try storage.saveValidated([ClipboardItem(text: "plain")])
        XCTAssertEqual(try richTextFiles(storage), [])

        let orphanURL = storage.richTextDirectoryURL.appendingPathComponent("orphan.rtf")
        try rtf.write(to: orphanURL)
        _ = storage.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    func testFailedRichTextCleanupIsReportedAsPendingCleanup() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        try storage.saveValidated([ClipboardItem(text: "rich", rtfData: rtf)])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: storage.richTextDirectoryURL.path
        )

        try storage.saveValidated([ClipboardItem(text: "plain")])
        XCTAssertTrue(storage.imageCleanupPending)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: storage.richTextDirectoryURL.path
        )
        try storage.saveValidated([ClipboardItem(text: "plain")])
        XCTAssertFalse(storage.imageCleanupPending)
        XCTAssertEqual(try richTextFiles(storage), [])
    }

    func testMissingRichTextSidecarDegradesToPlainText() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let item = ClipboardItem(text: "survives", rtfData: rtf, htmlData: html)
        try storage.saveValidated([item])
        for file in try richTextFiles(storage) {
            try FileManager.default.removeItem(
                at: storage.richTextDirectoryURL.appendingPathComponent(file)
            )
        }

        let loaded = try XCTUnwrap(storage.loadResult().get().first)

        XCTAssertEqual(loaded.id, item.id)
        XCTAssertEqual(loaded.text, "survives")
        XCTAssertEqual(loaded.contentKind, .text)
        XCTAssertFalse(loaded.hasRichText)
        let record = try XCTUnwrap(manifestRecords(storage).first)
        XCTAssertNil(record["rtfFileName"])
        XCTAssertNil(record["htmlFileName"])
    }

    func testOneMissingSidecarKeepsTheOtherRichTextFlavor() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        try storage.saveValidated([ClipboardItem(text: "half", rtfData: rtf, htmlData: html)])
        let rtfFile = try XCTUnwrap(richTextFiles(storage).first { $0.hasSuffix(".rtf") })
        try FileManager.default.removeItem(
            at: storage.richTextDirectoryURL.appendingPathComponent(rtfFile)
        )

        let loaded = try XCTUnwrap(storage.load().first)

        XCTAssertNil(loaded.rtfData)
        XCTAssertEqual(loaded.htmlData, html)
    }

    func testRichTextFileNamesOutsideTheSidecarDirectoryAreIgnored() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        try rtf.write(to: directory.appendingPathComponent("escaped.rtf"))
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "text":"escape",
          "contentKind":"text",
          "rtfFileName":"../escaped.rtf",
          "htmlFileName":"/etc/hosts"
        }]
        """
        try json.write(to: storage.fileURL, atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(storage.load().first)

        XCTAssertFalse(loaded.hasRichText)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("escaped.rtf").path)
        )
    }

    func testDecodingWithoutStorageIgnoresRichTextFileReferences() throws {
        let json = Data(
            #"{"text":"plain","contentKind":"text","rtfFileName":"x.rtf"}"#.utf8
        )
        let item = try JSONDecoder().decode(ClipboardItem.self, from: json)
        XCTAssertNil(item.rtfData)
    }

    func testInvalidHistoryQuarantinesRichTextSidecars() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        try storage.saveValidated([ClipboardItem(text: "rich", rtfData: rtf, htmlData: html)])
        let sidecars = try richTextFiles(storage)
        try "broken".write(to: storage.fileURL, atomically: true, encoding: .utf8)

        guard case let .failure(.invalidHistory(backupFileName)) = storage.loadResult() else {
            return XCTFail("Expected damaged history to be quarantined")
        }

        let recoveryURL = directory.appendingPathComponent(try XCTUnwrap(backupFileName))
        let quarantined = recoveryURL.appendingPathComponent("RichText", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: quarantined.path).sorted(),
            sidecars
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveryURL.appendingPathComponent("Images", isDirectory: true).path
            )
        )
        XCTAssertEqual(try richTextFiles(storage), [])
        XCTAssertEqual(try permissions(at: storage.richTextDirectoryURL), 0o700)

        try storage.saveValidated([ClipboardItem(text: "fresh", rtfData: rtf)])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: quarantined.path).sorted(),
            sidecars
        )
    }

    func testExportAndPreImportBackupEmbedRichTextInline() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let exportURL = directory.appendingPathComponent("export.json")
        try storage.saveValidated([ClipboardItem(text: "portable", rtfData: rtf, htmlData: html)])
        let loaded = storage.load()
        let fileNames = try richTextFiles(storage)

        try storage.export(loaded, to: exportURL)

        let exportText = try String(contentsOf: exportURL, encoding: .utf8)
        for fileName in fileNames {
            XCTAssertFalse(exportText.contains(fileName))
        }
        let imported = try XCTUnwrap(storage.importItems(from: exportURL).first)
        XCTAssertEqual(imported.rtfData, rtf)
        XCTAssertEqual(imported.htmlData, html)

        let backupURL = try storage.backup(loaded, reason: "pre-import")
        let document = try JSONDecoder().decode(
            ClipboardTransferDocument.self,
            from: Data(contentsOf: backupURL)
        )
        XCTAssertEqual(document.items.first?.rtfData, rtf)
        XCTAssertEqual(document.items.first?.htmlData, html)
    }

    func testRecoveryAndPreImportBackupsAreCappedIndependently() throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        for index in 0..<6 {
            _ = try storage.backup([ClipboardItem(text: "backup-\(index)")], reason: "pre-import")
        }
        for index in 0..<3 {
            try Data("broken-\(index)".utf8).write(to: storage.fileURL)
            guard case .failure(.invalidHistory) = storage.loadResult() else {
                return XCTFail("Expected invalid history to be quarantined")
            }
        }

        let names = try storage.backupInventory().urls.map(\.lastPathComponent)
        XCTAssertEqual(names.filter { $0.hasPrefix("Recovery-") }.count, 2)
        XCTAssertEqual(names.filter { $0.hasPrefix("clipboard-history.pre-import-") }.count, 5)
    }

    // MARK: - Helpers

    private final class FaultCounter: @unchecked Sendable {
        let point: ClipboardStorageFaultPoint
        var occurrence: Int
        private var visits = 0

        init(point: ClipboardStorageFaultPoint, occurrence: Int) {
            self.point = point
            self.occurrence = occurrence
        }

        func visit(_ visitedPoint: ClipboardStorageFaultPoint) throws {
            guard visitedPoint == point, occurrence > 0 else { return }
            visits += 1
            if visits == occurrence {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private func writeLegacyManifest(to storage: ClipboardStorage) throws {
        let json = """
        [{
          "id":"00000000-0000-0000-0000-000000000001",
          "text":"legacy rich",
          "contentKind":"text",
          "createdAt":0,
          "lastCopiedAt":0,
          "isPinned":false,
          "copyCount":1,
          "rtfData":"\(rtf.base64EncodedString())",
          "htmlData":"\(html.base64EncodedString())"
        }]
        """
        try json.write(to: storage.fileURL, atomically: true, encoding: .utf8)
    }

    private func manifestRecords(_ storage: ClipboardStorage) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: storage.fileURL))
        return try XCTUnwrap(root as? [[String: Any]])
    }

    private func richTextFiles(_ storage: ClipboardStorage) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: storage.richTextDirectoryURL.path).sorted()
    }

    private func fileNumbers(_ storage: ClipboardStorage) throws -> [String: Int] {
        var numbers: [String: Int] = [:]
        for file in try richTextFiles(storage) {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: storage.richTextDirectoryURL.appendingPathComponent(file).path
            )
            numbers[file] = try XCTUnwrap(attributes[.systemFileNumber] as? Int)
        }
        return numbers
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
}
