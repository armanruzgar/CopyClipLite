import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import CopyClipLite

private final class CountingClipboardImageReader: ClipboardImageReading, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var reads = 0

    init(data: Data) {
        self.data = data
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func imageData(for item: ClipboardItem) -> Data? {
        lock.withLock { reads += 1 }
        return data
    }
}

/// Reports the next removal, such as a drag stager deleting its session directory on deinit.
private final class RemovalSignallingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var nextRemoval: XCTestExpectation?

    func expectNextRemoval(_ description: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        lock.withLock { nextRemoval = expectation }
        return expectation
    }

    override func removeItem(at url: URL) throws {
        defer {
            lock.withLock {
                defer { nextRemoval = nil }
                return nextRemoval
            }?.fulfill()
        }
        try super.removeItem(at: url)
    }
}

private final class RecordingTransferRepository: ClipboardTransferRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var storedExportURL: URL?

    var exportURL: URL? {
        lock.withLock { storedExportURL }
    }

    func export(_ items: [ClipboardItem], to url: URL) throws {
        lock.withLock { storedExportURL = url }
        try Data("private history".utf8).write(to: url, options: .atomic)
    }

    func importItems(from url: URL) throws -> [ClipboardItem] {
        []
    }

    func importItems(data: Data) throws -> [ClipboardItem] {
        []
    }
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return attributes[.posixPermissions] as? Int ?? -1
}

@MainActor
final class ClipboardTransferRegressionTests: XCTestCase {
    func testCurrentAndLegacyImportsRejectUnsupportedTimestampBounds() throws {
        for timestamp in ["-1e30", "1e30"] {
            for field in ["createdAt", "lastCopiedAt"] {
                let record = """
                {"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","text":"synthetic",
                 "contentKind":"text","createdAt":\(field == "createdAt" ? timestamp : "0"),
                 "lastCopiedAt":\(field == "lastCopiedAt" ? timestamp : "0"),"isPinned":true,"copyCount":1}
                """
                for document in [
                    "[\(record)]",
                    "{\"format\":\"CopyClipLite\",\"version\":1,\"items\":[\(record)]}"
                ] {
                    XCTAssertThrowsError(try ClipboardTransferCodec.decode(Data(document.utf8))) { error in
                        XCTAssertEqual(
                            error as? ClipboardStorageError,
                            .invalidImportedItem("timestamps are outside the supported date range")
                        )
                    }
                }
            }
        }
    }

    func testOrdinaryOldPinnedDatesRemainPortableButUnsupportedLocalDatesDoNotExport() throws {
        let oldDate = Date(timeIntervalSince1970: -1_000_000)
        let valid = ClipboardItem(text: "old", createdAt: oldDate, lastCopiedAt: oldDate, isPinned: true)
        let data = try ClipboardTransferCodec.encode([valid])
        XCTAssertEqual(try ClipboardTransferCodec.decode(data), [valid])
        var invalid = valid
        invalid.lastCopiedAt = Date(timeIntervalSinceReferenceDate: -1e30)
        XCTAssertThrowsError(try ClipboardTransferCodec.encode([invalid]))
    }

    func testExportStagesOutsideDestinationAndAtomicallyMovesFinishedFile() async throws {
        let destinationDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CopyClipLite-ExportRegression-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: destinationDirectory) }
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = destinationDirectory.appendingPathComponent("History.json")
        let repository = RecordingTransferRepository()
        let service = ClipboardTransferService(storage: repository)

        try await service.export([ClipboardItem(text: "secret")], to: destinationURL)

        let stagedURL = try XCTUnwrap(repository.exportURL)
        XCTAssertNotEqual(stagedURL.deletingLastPathComponent(), destinationDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("private history".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path),
            ["History.json"]
        )
    }

    func testFileDragSuggestedNameUsesFilenameInsteadOfContainingFolder() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CopyClipLite-DragRegression-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = ClipboardDragProviderFactory(
            imageReader: CountingClipboardImageReader(data: Data()),
            stagingDirectory: root
        )
        let link = ClipboardLinkContent(
            url: URL(fileURLWithPath: "/Users/someone/Documents/notes.txt"),
            title: "Meeting notes"
        )

        let provider = factory.provider(for: ClipboardItem(link: link))

        XCTAssertEqual(link.subtitle, "/Users/someone/Documents")
        XCTAssertEqual(provider.suggestedName, "notes.txt")
    }

    func testImageDragStagingIsLazyPrivateAndRemovedWithProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CopyClipLite-DragRegression-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staleURL = root.appendingPathComponent("stale-private-image.png")
        try Data("stale".utf8).write(to: staleURL)

        let reader = CountingClipboardImageReader(data: Data("canonical png".utf8))
        let fileManager = RemovalSignallingFileManager()
        let factory = ClipboardDragProviderFactory(
            imageReader: reader,
            fileManager: fileManager,
            stagingDirectory: root
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertEqual(try posixPermissions(at: root), 0o700)

        var provider: NSItemProvider? = factory.provider(
            for: ClipboardItem(
                image: ClipboardImagePayload(data: nil, width: 1, height: 1)
            )
        )
        XCTAssertEqual(reader.readCount, 0, "Creating a drag provider must not read image data")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
            "Creating a drag provider must not stage image data"
        )

        let stagedPermissions: (directory: Int, file: Int) = try await withCheckedThrowingContinuation {
            continuation in
            provider?.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) {
                url,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    do {
                        continuation.resume(
                            returning: (
                                try posixPermissions(at: url.deletingLastPathComponent()),
                                try posixPermissions(at: url)
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: ClipboardStorageError.missingImageData)
                }
            }
        }
        XCTAssertEqual(stagedPermissions.directory, 0o700)
        XCTAssertEqual(stagedPermissions.file, 0o600)
        XCTAssertEqual(reader.readCount, 1)

        let sessionRemoved = fileManager.expectNextRemoval("drag session directory removed")
        provider = nil
        await fulfillment(of: [sessionRemoved], timeout: 10)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testLegacyReversedTimestampsNormalizeAndReExport() throws {
        let imported = try ClipboardTransferCodec.decode(
            Data(
                """
                [{
                  "id":"00000000-0000-0000-0000-000000000001",
                  "text":"legacy",
                  "createdAt":1000,
                  "lastCopiedAt":0,
                  "copyCount":1
                }]
                """.utf8
            ),
            now: Date(timeIntervalSinceReferenceDate: 2_000)
        )

        let item = try XCTUnwrap(imported.first)
        XCTAssertLessThanOrEqual(item.createdAt, item.lastCopiedAt)
        XCTAssertNoThrow(try ClipboardTransferCodec.encode(imported))
    }
}
