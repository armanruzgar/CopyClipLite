import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
    func testCopyImageItemWritesImagePasteboardTypes() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let pngData = try makePNGData(width: 2, height: 3)
        storage.save([
            ClipboardItem(image: ClipboardImagePayload(data: pngData, width: 2, height: 3))
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )
        let item = try XCTUnwrap(store.items.first)
        XCTAssertNil(item.image?.data)

        store.copy(item)

        XCTAssertEqual(pasteboard.data(forType: .png), pngData)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(store.items.first?.copyCount, 2)
    }

    func testImageCopyRequestsPNGWithoutEagerTIFFGeneration() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 2, height: 3),
                    width: 2,
                    height: 3
                )
            )
        ])
        let writer = StubPasteboardWriter(result: .success)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            pasteboardWriter: writer,
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )

        XCTAssertTrue(store.copy(try XCTUnwrap(store.items.first)))

        let request = try XCTUnwrap(writer.requests.first)
        XCTAssertEqual(request.required.map(\.type), [NSPasteboard.PasteboardType.png.rawValue])
        XCTAssertFalse(
            (request.required + request.optional)
                .contains { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }
        )
    }

    func testMissingImageDoesNotClearExistingClipboardOrReportCopySuccess() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 2, height: 2), width: 2, height: 2))
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil },
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )
        let item = try XCTUnwrap(store.items.first)
        for fileName in [item.image?.fileName, item.image?.thumbnailFileName].compactMap({ $0 }) {
            try FileManager.default.removeItem(
                at: storage.imageDirectoryURL.appendingPathComponent(fileName))
        }
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        XCTAssertFalse(store.copy(item))

        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
        XCTAssertEqual(store.items.first?.copyCount, 1)
        XCTAssertNotNil(store.storageErrorMessage)
    }

    func testImagePasteboardWithAssociatedTextKeepsText() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )
        let pngData = try makePNGData(width: 4, height: 5)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        XCTAssertTrue(pasteboard.setString("chart caption", forType: .string))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.contentKind, .image)
        XCTAssertEqual(item.text, "chart caption")
        XCTAssertEqual(item.previewText, "Image · chart caption")
        XCTAssertEqual(store.visibleItems(matching: "caption").map(\.id), [item.id])

        store.copy(item)

        try assertReadableImageData(pasteboard.data(forType: .png))
        XCTAssertEqual(pasteboard.string(forType: .string), "chart caption")
    }

    func testTextCaptureDoesNotDeduplicateAgainstImageCaption() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = try makePNGData(width: 2, height: 2)
        storage.save([
            ClipboardItem(
                text: "same content",
                image: ClipboardImagePayload(data: imageData, width: 2, height: 2)
            )
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("same content", forType: .string))
        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.filter { $0.contentKind == .text }.count, 1)
        XCTAssertEqual(store.items.filter { $0.contentKind == .image }.count, 1)

        let imageItem = try XCTUnwrap(
            store.items.first(where: { $0.contentKind == .image })
        )
        let textItem = try XCTUnwrap(
            store.items.first(where: { $0.contentKind == .text })
        )
        XCTAssertTrue(store.copy(imageItem))
        try assertReadableImageData(pasteboard.data(forType: .png))
        XCTAssertTrue(store.copy(textItem))
        XCTAssertEqual(pasteboard.string(forType: .string), "same content")
    }

    func testTransformationDoesNotDeduplicateAgainstImageCaption() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = try makePNGData(width: 2, height: 2)
        storage.save([
            ClipboardItem(
                text: "HELLO",
                image: ClipboardImagePayload(data: imageData, width: 2, height: 2)
            ),
            ClipboardItem(text: "hello"),
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )
        let textItem = try XCTUnwrap(store.items.first(where: { $0.contentKind == .text }))
        let originalImageItem = try XCTUnwrap(
            store.items.first(where: { $0.contentKind == .image })
        )

        store.copyWithTransformation(textItem, transformation: .uppercase)

        XCTAssertEqual(store.items.filter { $0.contentKind == .image }.count, 1)
        XCTAssertEqual(
            store.items.first(where: { $0.contentKind == .image }),
            originalImageItem
        )
        XCTAssertEqual(
            store.items.filter { $0.contentKind == .text && $0.text == "HELLO" }.count,
            1
        )
        XCTAssertTrue(store.copy(originalImageItem))
        try assertReadableImageData(pasteboard.data(forType: .png))
    }

    func testPollingCapturesRTFAndHTMLData() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )

        let rtfData = "{\\rtf1\\ansi Hello}".data(using: .utf8)!
        let htmlData = "<b>Hello</b>".data(using: .utf8)!

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("Hello", forType: .string))
        XCTAssertTrue(pasteboard.setData(rtfData, forType: .rtf))
        XCTAssertTrue(pasteboard.setData(htmlData, forType: .html))

        store.pollPasteboardForChanges()

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.text, "Hello")
        XCTAssertEqual(item.rtfData, rtfData)
        XCTAssertEqual(item.htmlData, htmlData)
        XCTAssertTrue(item.hasRichText)
    }

    func testMaximumLengthTextCapturesAtBoundary() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )
        let text = String(repeating: "a", count: 20_000)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text.count, 20_000)
        XCTAssertNil(store.captureWarning)
    }

    func testSuccessfulCaptureClearsOnlyItsCaptureIssue() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )
        let item = ClipboardItem(text: "paste issue probe")
        let pasteController = makePasteControllerWithPermissionError(
            item: item,
            store: store
        )
        let independentPasteIssue = try XCTUnwrap(pasteController.lastError)

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setString(
                String(repeating: "x", count: 20_001),
                forType: .string
            )
        )
        store.pollPasteboardForChanges()
        XCTAssertNotNil(store.captureWarning)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("valid recovery", forType: .string))
        store.pollPasteboardForChanges()

        XCTAssertNil(store.captureWarning)
        XCTAssertEqual(pasteController.lastError, independentPasteIssue)
        XCTAssertEqual(store.items.first?.text, "valid recovery")
    }

    func testRTFAndHTMLBoundaryPayloadsCaptureExportAndReimport() throws {
        let directory = try makeTemporaryDirectory()
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            dragStagingDirectory: makeIsolatedDragStagingDirectory()
        )
        let boundary = ClipboardStorage.maximumImportedRichTextBytes
        let rtfData = Data(repeating: 0x52, count: boundary)
        let htmlData = Data(repeating: 0x48, count: boundary)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("boundary rich text", forType: .string))
        XCTAssertTrue(pasteboard.setData(rtfData, forType: .rtf))
        XCTAssertTrue(pasteboard.setData(htmlData, forType: .html))

        store.pollPasteboardForChanges()

        let captured = try XCTUnwrap(store.items.first)
        XCTAssertEqual(captured.rtfData?.count, boundary)
        XCTAssertEqual(captured.htmlData?.count, boundary)
        XCTAssertNil(store.captureWarning)

        let exportURL = directory.appendingPathComponent("rich-boundary.json")
        try storage.export(store.items, to: exportURL)
        let imported = try storage.importItems(from: exportURL)
        XCTAssertEqual(imported.first?.rtfData, rtfData)
        XCTAssertEqual(imported.first?.htmlData, htmlData)
    }
}
