import AppKit
import Foundation
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
    func testCapturedWebURLAtCharacterLimitPersistsAndExports() async throws {
        for scheme in ["http", "https"] {
            let prefix = "\(scheme)://example.com/?q="
            let urlString = prefix + String(repeating: "x", count: 20_000 - prefix.count)
            let url = try XCTUnwrap(URL(string: urlString))
            XCTAssertEqual(url.absoluteString.count, 20_000)

            let directory = try makeTemporaryDirectory()
            let storage = ClipboardStorage(appDirectory: directory)
            let pasteboard = makePasteboard()
            let store = ClipboardStore(
                pasteboard: pasteboard,
                storage: storage,
                defaults: makeIsolatedDefaults(),
                sourceApplicationProvider: { nil }
            )
            defer { store.setMonitoringEnabled(false) }
            pasteboard.setString(urlString, forType: .URL)
            pasteboard.setString(urlString, forType: .string)

            store.pollPasteboardForChanges()

            XCTAssertEqual(store.items.count, 1)
            let item = try XCTUnwrap(store.items.first)
            XCTAssertEqual(item.contentKind, .link)
            XCTAssertEqual(item.linkURL, url)
            XCTAssertEqual(item.text, urlString)
            XCTAssertNil(store.captureWarning)
            let persisted = await store.flushPendingPersist()
            XCTAssertTrue(persisted)
            XCTAssertEqual(try storage.loadResult().get(), store.items)

            let exportURL = directory.appendingPathComponent("export.json")
            try await store.exportHistoryAsync(to: exportURL)
            XCTAssertEqual(try storage.importItems(from: exportURL), store.items)
        }
    }

    func testOversizedWebURLWithoutPlainTextDoesNotBlockHistoryExport() async throws {
        for scheme in ["http", "https"] {
            let prefix = "\(scheme)://example.com/?q="
            let urlString = prefix + String(repeating: "x", count: 20_001 - prefix.count)
            try await assertOversizedWebURLIsSkipped(urlString)
        }
    }

    func testOversizedWebURLWithPlainTextPreservesAccurateWarning() async throws {
        for scheme in ["http", "https"] {
            let prefix = "\(scheme)://example.com/?q="
            let urlString = prefix + String(repeating: "x", count: 20_001 - prefix.count)
            try await assertOversizedWebURLIsSkipped(urlString, plainText: urlString)
        }
    }

    func testWebURLThatExceedsLimitAfterEncodingIsSkipped() async throws {
        for scheme in ["http", "https"] {
            let prefix = "\(scheme)://example.com/?q="
            let urlString = prefix + String(repeating: "x", count: 19_999 - prefix.count) + "é"
            XCTAssertEqual(urlString.count, 20_000)
            try await assertOversizedWebURLIsSkipped(urlString, plainText: urlString)
        }
    }

    private func assertOversizedWebURLIsSkipped(
        _ urlString: String,
        plainText: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = try XCTUnwrap(URL(string: urlString), file: file, line: line)
        XCTAssertGreaterThan(url.absoluteString.count, 20_000, file: file, line: line)
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory)
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        defer { store.setMonitoringEnabled(false) }
        pasteboard.setString("keep this valid clip", forType: .string)
        store.pollPasteboardForChanges()
        let existingItems = store.items
        XCTAssertEqual(existingItems.count, 1, file: file, line: line)

        pasteboard.clearContents()
        pasteboard.setString(urlString, forType: .URL)
        if let plainText {
            pasteboard.setString(plainText, forType: .string)
        }

        store.pollPasteboardForChanges()

        let expectedWarning = "A link clip was skipped because its URL exceeds 20,000 characters."
        XCTAssertEqual(store.items, existingItems, file: file, line: line)
        XCTAssertEqual(store.captureWarning, expectedWarning, file: file, line: line)
        store.pollPasteboardForChanges()
        XCTAssertEqual(store.captureWarning, expectedWarning, file: file, line: line)
        let persisted = await store.flushPendingPersist()
        XCTAssertTrue(persisted, file: file, line: line)
        XCTAssertEqual(try storage.loadResult().get(), existingItems, file: file, line: line)

        let exportURL = directory.appendingPathComponent("export.json")
        try await store.exportHistoryAsync(to: exportURL)
        XCTAssertEqual(
            try storage.importItems(from: exportURL), existingItems, file: file, line: line
        )

        pasteboard.clearContents()
        pasteboard.setString("https://example.com/valid", forType: .URL)
        store.pollPasteboardForChanges()
        XCTAssertEqual(store.items.count, existingItems.count + 1, file: file, line: line)
        XCTAssertEqual(store.items.first?.contentKind, .link, file: file, line: line)
        XCTAssertNil(store.captureWarning, file: file, line: line)
    }
}
