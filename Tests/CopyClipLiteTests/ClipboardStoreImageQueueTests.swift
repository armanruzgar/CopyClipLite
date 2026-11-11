import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
    func testFlushExternalizesLiveImagePayloadWithoutBreakingCopy() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        let pngData = try makePNGData(width: 3, height: 3)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)
        XCTAssertNotNil(store.items.first?.image?.data)

        let didFlush = await store.flushPendingPersist()
        XCTAssertTrue(didFlush)

        let externalizedItem = try XCTUnwrap(store.items.first)
        XCTAssertNil(externalizedItem.image?.data)
        XCTAssertNotNil(externalizedItem.image?.fileName)
        XCTAssertTrue(store.copy(externalizedItem))
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }

    func testLiveImageStressExternalizesPayloadsAndBoundsResidentMemory() async throws {
        let payloadByteCount = 2 * 1024 * 1024
        let captureCount = 48
        let maximumResidentGrowth = UInt64(80 * 1024 * 1024)
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let writer = StubPasteboardWriter(result: .success)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil },
            imageProcessor: ExternalizingStressImageProcessor(
                payloadByteCount: payloadByteCount
            ),
            pasteboardWriter: writer
        )
        store.setHistoryLimit(200)

        ProcessMemoryMetrics.relieveAllocatorPressure()
        let baselineResidentBytes = try ProcessMemoryMetrics.residentSizeBytes()

        for marker in 1...captureCount {
            pasteboard.clearContents()
            XCTAssertTrue(
                pasteboard.setData(
                    Data([UInt8(marker)]),
                    forType: .png
                )
            )
            store.pollPasteboardForChanges()
            await waitForState(of: store, "capture \(marker)") { store.items.count >= marker }
            XCTAssertEqual(store.items.count, marker)
            let didFlush = await store.flushPendingPersist()
            XCTAssertTrue(didFlush)
            XCTAssertEqual(
                store.items.reduce(0) {
                    $0 + ($1.image?.data?.count ?? 0)
                        + ($1.image?.thumbnailData?.count ?? 0)
                },
                0
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        ProcessMemoryMetrics.relieveAllocatorPressure()
        let finalResidentBytes = try ProcessMemoryMetrics.residentSizeBytes()
        let residentGrowth = ProcessMemoryMetrics.positiveGrowth(
            from: baselineResidentBytes,
            to: finalResidentBytes
        )

        XCTAssertEqual(store.items.count, captureCount)
        XCTAssertLessThan(
            residentGrowth,
            maximumResidentGrowth,
            "Committed live images retained \(residentGrowth) bytes of resident memory"
        )
        let first = try XCTUnwrap(store.items.first)
        let last = try XCTUnwrap(store.items.last)
        XCTAssertTrue(store.copy(first))
        XCTAssertTrue(store.copy(last))
        XCTAssertEqual(writer.requests.count, 2)
        XCTAssertEqual(
            writer.requests.map { request in
                request.required.reduce(0) {
                    guard case .data(let data) = $1.value else { return $0 }
                    return $0 + data.count
                }
            },
            [payloadByteCount, payloadByteCount]
        )
    }

    func testAsyncThumbnailLookupRepairsSidecarDeletedAfterInitialization() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let imageData = try makePNGData(width: 8, height: 8)
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: imageData,
                    width: 8,
                    height: 8
                )
            )
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        let item = try XCTUnwrap(store.items.first)
        let oldThumbnailName = try XCTUnwrap(item.image?.thumbnailFileName)
        try FileManager.default.removeItem(
            at: storage.imageDirectoryURL.appendingPathComponent(oldThumbnailName)
        )

        XCTAssertNil(store.cachedThumbnailData(for: item))
        await waitForState(of: store, "repaired thumbnail") {
            store.cachedThumbnailData(for: item) != nil
        }

        let repairedData = try XCTUnwrap(store.cachedThumbnailData(for: item))
        XCTAssertTrue(ClipboardImageProcessor.isDecodableImage(repairedData))
        XCTAssertEqual(store.cachedThumbnailData(for: item), repairedData)
        let repairedName = try XCTUnwrap(store.items.first?.image?.thumbnailFileName)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storage.imageDirectoryURL
                    .appendingPathComponent(repairedName)
                    .path
            )
        )
    }

    func testEvictingUnrelatedClipKeepsSurvivingThumbnailCached() async throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let now = Date()
        let imageItem = ClipboardItem(
            image: ClipboardImagePayload(
                data: try makePNGData(width: 2, height: 2),
                width: 2,
                height: 2
            ),
            createdAt: now,
            lastCopiedAt: now,
            isPinned: true
        )
        let unpinnedItems = (0..<10).map { index in
            let timestamp = now.addingTimeInterval(TimeInterval(-index))
            return ClipboardItem(
                text: "clip-\(index)",
                createdAt: timestamp,
                lastCopiedAt: timestamp
            )
        }
        storage.save([imageItem] + unpinnedItems)
        let counter = LockedThumbnailLoadCounter()
        let thumbnailData = Data([1, 2, 3])
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil },
            thumbnailLoader: { item in
                counter.increment()
                return ClipboardThumbnailResult(
                    data: thumbnailData,
                    fileName: item.image?.thumbnailFileName ?? "test-thumbnail.png"
                )
            }
        )
        store.setHistoryLimit(10)
        let storedImage = try XCTUnwrap(store.items.first(where: \.isImage))

        XCTAssertNil(store.cachedThumbnailData(for: storedImage))
        await waitForState(of: store, "loaded thumbnail") {
            store.cachedThumbnailData(for: storedImage) != nil
        }
        XCTAssertEqual(store.cachedThumbnailData(for: storedImage), thumbnailData)
        XCTAssertEqual(counter.value, 1)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("newest unrelated clip", forType: .string))
        store.pollPasteboardForChanges()

        let survivingImage = try XCTUnwrap(store.items.first(where: \.isImage))
        XCTAssertEqual(store.cachedThumbnailData(for: survivingImage), thumbnailData)
        XCTAssertEqual(counter.value, 1)
    }

    func testClearInvalidatesPendingImageCapture() async throws {
        let pasteboard = makePasteboard()
        let processor = GatedImageProcessor()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            imageProcessor: processor
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([1, 2, 3]), forType: .png))
        store.pollPasteboardForChanges()
        await fulfillment(of: [processor.firstStarted], timeout: 10)
        await store.clearHistory()
        await processor.release()

        // Delivered after the cleared capture's outcome, so that outcome would show up first.
        try await captureImageSentinel(in: store, pasteboard: pasteboard)
        XCTAssertEqual(store.items.map(\.image?.contentHash), [Self.imageSentinelHash])
        let started = await processor.started()
        XCTAssertEqual(started, [Data([1, 2, 3]), Self.imageSentinel])
    }

    func testRapidImageCapturesKeepOneInFlightAndLatestSevenQueuedInOrder() async throws {
        let pasteboard = makePasteboard()
        let processor = RecordingDelayedImageProcessor(delayNanoseconds: 40_000_000)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil },
            imageProcessor: processor
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([0]), forType: .png))
        XCTAssertTrue(pasteboard.setString("capture-0", forType: .string))
        store.pollPasteboardForChanges()
        await fulfillment(of: [processor.firstStarted], timeout: 10)
        let initiallyStarted = await processor.started()
        XCTAssertEqual(initiallyStarted, [Data([0])])

        for value in 1..<20 {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setData(Data([UInt8(value)]), forType: .png))
            XCTAssertTrue(pasteboard.setString("capture-\(value)", forType: .string))
            store.pollPasteboardForChanges()
        }

        await waitForState(of: store, "eight captures") { store.items.count >= 8 }

        XCTAssertEqual(store.items.count, 8)
        XCTAssertEqual(
            Set(store.items.map(\.text)),
            Set(["capture-0"] + (13..<20).map { "capture-\($0)" })
        )
        let allStarted = await processor.started()
        XCTAssertEqual(allStarted, [Data([0])] + (13..<20).map { Data([UInt8($0)]) })
    }

    func testQuitCleanupCancelsPendingImageCapture() async throws {
        let pasteboard = makePasteboard()
        let processor = GatedImageProcessor()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil },
            imageProcessor: processor
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([1]), forType: .png))
        store.pollPasteboardForChanges()
        await fulfillment(of: [processor.firstStarted], timeout: 10)

        store.clearUnpinnedHistoryOnQuitIfNeeded()
        XCTAssertTrue(store.items.isEmpty)
        await processor.release()

        // Delivered after the cancelled capture's outcome, so that outcome would show up first.
        try await captureImageSentinel(in: store, pasteboard: pasteboard)
        XCTAssertEqual(store.items.map(\.image?.contentHash), [Self.imageSentinelHash])
        let started = await processor.started()
        XCTAssertEqual(started, [Data([1]), Self.imageSentinel])
    }

    func testDuplicateImageRefreshesAssociatedText() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults()
        )
        let pngData = try makePNGData(width: 2, height: 2)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        XCTAssertTrue(pasteboard.setString("caption A", forType: .string))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        XCTAssertTrue(pasteboard.setString("caption B", forType: .string))
        store.pollPasteboardForChanges()
        try await waitForCopyCount(2, in: store)

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(item.text, "caption B")
        XCTAssertEqual(item.previewText, "Image · caption B")
        XCTAssertEqual(store.visibleItems(matching: "caption B").map(\.id), [item.id])
    }

    func testDuplicateImageRefreshesTextToEmptyAndBackToText() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults()
        )
        let pngData = try makePNGData(width: 2, height: 2)

        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        pasteboard.setString("first", forType: .string)
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        store.pollPasteboardForChanges()
        try await waitForCopyCount(2, in: store)
        XCTAssertEqual(store.items.first?.text, "")

        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        pasteboard.setString("restored", forType: .string)
        store.pollPasteboardForChanges()
        try await waitForCopyCount(3, in: store)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "restored")
        XCTAssertEqual(store.items.first?.previewText, "Image · restored")
    }

    func testOlderImageCompletionCannotOverwriteNewestAssociatedText() async throws {
        let pasteboard = makePasteboard()
        let imageData = try makePNGData(width: 2, height: 2)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil },
            imageProcessor: SequencedImageProcessor()
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(imageData, forType: .png))
        XCTAssertTrue(pasteboard.setString("older caption", forType: .string))
        store.pollPasteboardForChanges()

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(imageData, forType: .png))
        XCTAssertTrue(pasteboard.setString("newest caption", forType: .string))
        store.pollPasteboardForChanges()
        try await waitForCopyCount(2, in: store)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.copyCount, 2)
        XCTAssertEqual(store.items.first?.text, "newest caption")
    }

    func testLegacyRawPNGRecopyDeduplicatesAgainstCanonicalCapture() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let rawPNG = try makePNGData(width: 3, height: 3)
        let imageFileName = "legacy-raw.png"
        try rawPNG.write(
            to: storage.imageDirectoryURL.appendingPathComponent(imageFileName)
        )
        let legacyJSON = """
            [{
              "id":"00000000-0000-0000-0000-000000000001",
              "text":"legacy",
              "contentKind":"image",
              "image":{
                "fileName":"\(imageFileName)",
                "width":3,
                "height":3,
                "byteCount":\(rawPNG.count)
              },
              "copyCount":1
            }]
            """
        try legacyJSON.write(to: storage.fileURL, atomically: true, encoding: .utf8)
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(rawPNG, forType: .png))
        XCTAssertTrue(pasteboard.setString("latest", forType: .string))
        store.pollPasteboardForChanges()
        try await waitForCopyCount(2, in: store)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "latest")
        XCTAssertEqual(
            store.items.first?.image?.contentHash,
            try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: rawPNG, isPNG: true)
            ).contentHash
        )
    }

    func testDeletingAnotherClipKeepsLiveCapturedImageFilesReadable() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        let pngData = try makePNGData(width: 4, height: 4)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)
        let imageID = try XCTUnwrap(store.items.first?.id)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("delete me", forType: .string))
        store.pollPasteboardForChanges()
        let textItem = try XCTUnwrap(store.items.first(where: { $0.text == "delete me" }))

        await store.delete(textItem)

        let reloadedImage = try XCTUnwrap(storage.load().first(where: { $0.id == imageID }))
        try assertReadableImageData(storage.imageData(for: reloadedImage))
        XCTAssertNotNil(storage.thumbnailData(for: reloadedImage))

        let reloadedPasteboard = makePasteboard()
        let reloadedStore = ClipboardStore(
            pasteboard: reloadedPasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        let reloadedStoreImage = try XCTUnwrap(
            reloadedStore.items.first(where: { $0.id == imageID })
        )
        XCTAssertTrue(reloadedStore.copy(reloadedStoreImage))
        try assertReadableImageData(reloadedPasteboard.data(forType: .png))
    }

    func testClearKeepingPinnedKeepsLiveCapturedImageFilesReadable() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults()
        )
        let pngData = try makePNGData(width: 5, height: 5)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))
        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)
        let imageItem = try XCTUnwrap(store.items.first)
        store.togglePin(imageItem)

        await store.clearHistory()

        let reloadedImage = try XCTUnwrap(storage.load().first)
        XCTAssertTrue(reloadedImage.isPinned)
        try assertReadableImageData(storage.imageData(for: reloadedImage))
        XCTAssertNotNil(storage.thumbnailData(for: reloadedImage))

        let reloadedPasteboard = makePasteboard()
        let reloadedStore = ClipboardStore(
            pasteboard: reloadedPasteboard,
            storage: storage,
            defaults: makeIsolatedDefaults(),
            sourceApplicationProvider: { nil }
        )
        let reloadedStoreImage = try XCTUnwrap(reloadedStore.items.first)
        XCTAssertTrue(reloadedStoreImage.isPinned)
        XCTAssertTrue(reloadedStore.copy(reloadedStoreImage))
        try assertReadableImageData(reloadedPasteboard.data(forType: .png))
    }
}

extension ClipboardStoreTests {
    static let imageSentinel = Data([0xC0, 0xFF, 0xEE])
    static let imageSentinelHash = ClipboardImageProcessor.contentHash(for: imageSentinel)

    /// Captures an image through the store's serial image queue and waits for it.
    func captureImageSentinel(
        in store: ClipboardStore,
        pasteboard: StubStorePasteboard
    ) async throws {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Self.imageSentinel, forType: .png))
        store.pollPasteboardForChanges()
        await waitForState(of: store, "image sentinel") {
            store.items.contains { $0.image?.contentHash == Self.imageSentinelHash }
        }
    }
}

private final class LockedThumbnailLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
