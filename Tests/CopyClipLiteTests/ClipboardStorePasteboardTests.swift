import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
    func testOptionalPasteboardWriteFailureIsReportedAsDegradedCopy() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                text: "hello",
                rtfData: Data("rtf".utf8),
                htmlData: Data("html".utf8)
            )
        ])
        let writer = StubPasteboardWriter(
            result: .degraded(optionalTypes: [NSPasteboard.PasteboardType.rtf.rawValue])
        )
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            pasteboardWriter: writer
        )

        XCTAssertTrue(store.copy(try XCTUnwrap(store.items.first)))
        XCTAssertEqual(store.items.first?.copyCount, 2)
        XCTAssertTrue(store.pasteboardWriteWarning?.contains("optional formats") == true)
    }

    func testOptionalPasteboardRepresentationFailureMatrixReportsDegradation() throws {
        for failedType in [
            NSPasteboard.PasteboardType.rtf,
            NSPasteboard.PasteboardType.html,
        ] {
            let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
            storage.save([
                ClipboardItem(
                    text: "rich",
                    rtfData: Data("rtf".utf8),
                    htmlData: Data("html".utf8)
                )
            ])
            let writer = SelectiveFailurePasteboardWriter(
                failingTypes: [failedType.rawValue]
            )
            let store = ClipboardStore(
                pasteboard: makePasteboard(),
                storage: storage,
                defaults: makeIsolatedDefaults(),
                pasteboardWriter: writer
            )

            XCTAssertTrue(store.copy(try XCTUnwrap(store.items.first)))
            XCTAssertEqual(store.items.first?.copyCount, 2)
            XCTAssertEqual(
                writer.requests.first?.optional.map(\.type),
                [
                    NSPasteboard.PasteboardType.rtf.rawValue,
                    NSPasteboard.PasteboardType.html.rawValue,
                ]
            )
            XCTAssertTrue(
                store.pasteboardWriteWarning?.contains(failedType.rawValue) == true
            )
            XCTAssertNil(store.storageErrorMessage)
        }

        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                text: "associated text",
                image: ClipboardImagePayload(
                    data: try makePNGData(width: 2, height: 2),
                    width: 2,
                    height: 2
                )
            )
        ])
        let writer = SelectiveFailurePasteboardWriter(
            failingTypes: [NSPasteboard.PasteboardType.string.rawValue]
        )
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            pasteboardWriter: writer
        )

        XCTAssertTrue(store.copy(try XCTUnwrap(store.items.first)))
        XCTAssertEqual(store.items.first?.copyCount, 2)
        XCTAssertEqual(
            writer.requests.first?.required.map(\.type),
            [NSPasteboard.PasteboardType.png.rawValue]
        )
        XCTAssertEqual(
            writer.requests.first?.optional.map(\.type),
            [NSPasteboard.PasteboardType.string.rawValue]
        )
        XCTAssertTrue(
            store.pasteboardWriteWarning?
                .contains(NSPasteboard.PasteboardType.string.rawValue) == true
        )
        XCTAssertNil(store.storageErrorMessage)
    }

    func testCopyWithTransformationRecordsTransformedText() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "hello world")])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        let item = try XCTUnwrap(store.items.first)

        store.copyWithTransformation(item, transformation: .uppercase)

        XCTAssertEqual(pasteboard.string(forType: .string), "HELLO WORLD")
        let transformedItem = try XCTUnwrap(store.items.first)
        XCTAssertEqual(transformedItem.text, "HELLO WORLD")
        XCTAssertEqual(transformedItem.copyCount, 1)
        XCTAssertEqual(store.lastCopiedID, transformedItem.id)
    }

    func testCopyWithTransformationRejectsTextThatExpandsPastExportLimit() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let sourceText = String(
            repeating: "ß",
            count: ClipboardStorage.maximumImportedTextCharacters
        )
        storage.save([ClipboardItem(text: sourceText)])
        let writer = StubPasteboardWriter(result: .success)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            pasteboardWriter: writer
        )
        let originalItems = store.items

        store.copyWithTransformation(
            try XCTUnwrap(store.items.first),
            transformation: .uppercase
        )

        XCTAssertTrue(writer.requests.isEmpty)
        XCTAssertEqual(store.items, originalItems)
        XCTAssertTrue(store.captureWarning?.contains("20,000") == true)
    }

    func testCopyWithTransformationDeduplicatesExistingItem() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(text: "HELLO WORLD"),
            ClipboardItem(text: "hello world"),
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        let item = try XCTUnwrap(store.items.first(where: { $0.text == "hello world" }))

        store.copyWithTransformation(item, transformation: .uppercase)

        XCTAssertEqual(store.items.filter { $0.text == "HELLO WORLD" }.count, 1)
        let transformedItem = try XCTUnwrap(store.items.first)
        XCTAssertEqual(transformedItem.text, "HELLO WORLD")
        XCTAssertEqual(transformedItem.copyCount, 2)
    }

    func testCopyWithoutFormattingCopiesWhitespaceOnlyLegacyTextExactly() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(text: "   ")])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        let item = try XCTUnwrap(store.items.first)

        XCTAssertTrue(store.copyWithoutFormatting(item))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "   ")
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertNil(pasteboard.data(forType: .html))
    }

    func testCopyWithoutFormattingPreservesExactWhitespaceAndUnicode() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let exactText = "  let café = \"☕️\"\n\n\tprint(café)  "
        storage.save([ClipboardItem(text: exactText, rtfData: Data("rtf".utf8))])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults()
        )

        XCTAssertTrue(
            store.copyWithoutFormatting(try XCTUnwrap(store.items.first))
        )

        XCTAssertEqual(pasteboard.string(forType: .string), exactText)
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertNil(pasteboard.data(forType: .html))
    }

    func testCopyWithoutFormattingSendsNoRichTextRepresentationsToWriter() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([
            ClipboardItem(
                text: "plain result",
                rtfData: Data("rich rtf".utf8),
                htmlData: Data("rich html".utf8)
            )
        ])
        let writer = StubPasteboardWriter(result: .success)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            pasteboardWriter: writer
        )

        XCTAssertTrue(
            store.copyWithoutFormatting(try XCTUnwrap(store.items.first))
        )

        let request = try XCTUnwrap(writer.requests.first)
        XCTAssertEqual(
            request.required,
            [ClipboardPasteboardRepresentation(.string, value: .string("plain result"))]
        )
        XCTAssertTrue(request.optional.isEmpty)
        XCTAssertEqual(store.items.first?.copyCount, 2)
    }

    func testPollingExtractsPlainTextFromRTFWithoutStringFlavor() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults()
        )
        let attributed = NSAttributedString(string: "RTF only")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(rtf, forType: .rtf))

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text, "RTF only")
        XCTAssertEqual(store.items.first?.rtfData, rtf)
    }

    func testOversizedTextShowsWarningInsteadOfDisappearingSilently() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults()
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(String(repeating: "a", count: 20_001), forType: .string))

        store.pollPasteboardForChanges()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.captureWarning?.contains("20,000") == true)
    }

    func testOversizedRichTextIsDroppedWithWarningWhilePlainTextSurvives() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults()
        )
        pasteboard.clearContents()
        pasteboard.setString("plain survives", forType: .string)
        pasteboard.setData(
            Data(repeating: 0x41, count: ClipboardStorage.maximumImportedRichTextBytes + 1),
            forType: .rtf
        )

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text, "plain survives")
        XCTAssertNil(store.items.first?.rtfData)
        XCTAssertTrue(store.captureWarning?.contains("oversized RTF") == true)
    }

    func testOversizedHTMLIsDroppedWithSpecificWarning() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults()
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("plain survives", forType: .string))
        XCTAssertTrue(
            pasteboard.setData(
                Data(
                    repeating: 0x48,
                    count: ClipboardStorage.maximumImportedRichTextBytes + 1
                ),
                forType: .html
            )
        )

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text, "plain survives")
        XCTAssertNil(store.items.first?.htmlData)
        XCTAssertTrue(store.captureWarning?.contains("oversized HTML") == true)
    }

    func testPollingExtractsPlainTextFromHTMLWithoutStringFlavor() throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults()
        )
        let html = Data("<p>HTML <strong>only</strong></p>".utf8)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(html, forType: .html))

        store.pollPasteboardForChanges()

        XCTAssertEqual(store.items.first?.text, "HTML only")
        XCTAssertEqual(store.items.first?.htmlData, html)
    }

    func testCopyWritesRTFAndHTMLToPasteboard() throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let rtfData = "{\\rtf1\\ansi Hello}".data(using: .utf8)!
        let htmlData = "<b>Hello</b>".data(using: .utf8)!
        storage.save([
            ClipboardItem(text: "Hello", rtfData: rtfData, htmlData: htmlData)
        ])
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        let item = try XCTUnwrap(store.items.first)

        store.copy(item)

        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtfData)
        XCTAssertEqual(pasteboard.data(forType: .html), htmlData)
    }

    func testTextDragProviderOffersPlainAndRichRepresentationsWithoutMutation() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let rtfData = Data(#"{\rtf1\ansi drag me}"#.utf8)
        let htmlData = Data("<strong>drag me</strong>".utf8)
        storage.save([
            ClipboardItem(text: "drag me", rtfData: rtfData, htmlData: htmlData)
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        let item = try XCTUnwrap(store.items.first)

        let provider = store.dragItemProvider(for: item)

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.html.identifier))
        let loadedRTF: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.rtf.identifier) {
                data,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ClipboardStorageError.missingImageData)
                }
            }
        }
        let loadedHTML: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.html.identifier) {
                data,
                error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ClipboardStorageError.missingImageData)
                }
            }
        }
        XCTAssertEqual(loadedRTF, rtfData)
        XCTAssertEqual(loadedHTML, htmlData)
        XCTAssertEqual(store.items.first?.copyCount, 1)
    }
}
