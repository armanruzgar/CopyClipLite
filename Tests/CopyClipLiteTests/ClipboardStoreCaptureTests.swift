import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CopyClipLite

@MainActor
extension ClipboardStoreTests {
    func testPollingCapturesImagePasteboardData() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 3, height: 4)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        let item = try XCTUnwrap(store.items.first)
        let image = try XCTUnwrap(item.image)
        XCTAssertEqual(item.contentKind, .image)
        XCTAssertNotNil(image.data)
        XCTAssertNotNil(image.thumbnailData)
        XCTAssertNotNil(image.contentHash)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 4)
        XCTAssertEqual(item.previewText, "Image")
        XCTAssertEqual(store.visibleItems(matching: "image").map(\.id), [item.id])
    }

    func testMaximumSupportedValidImageCopyDoesNotDecodeOrBlockMainActor() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let side = 4_096
        XCTAssertEqual(side * side, ClipboardImageProcessor.maximumPixelCount)
        let maximumDimensionPNG = try makeSolidPNGData(width: side, height: side)
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(
                    data: maximumDimensionPNG,
                    width: side,
                    height: side
                )
            )
        ])
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let item = try XCTUnwrap(store.items.first)
        let start = ContinuousClock.now

        XCTAssertTrue(store.copy(item))

        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(pasteboard.data(forType: .png), maximumDimensionPNG)
    }

    func testNearEncodedLimitValidImageCopyMeetsLatencyAndResidentBudgets() throws {
        let maximumCopyLatency = Duration.seconds(1)
        let maximumResidentGrowth = UInt64(
            ClipboardImageProcessor.maximumEncodedBytes + 32 * 1024 * 1024
        )
        let image = try NearLimitImageFixture.canonicalPNG()
        let imageData = try XCTUnwrap(image.data)
        XCTAssertGreaterThanOrEqual(
            imageData.count,
            ClipboardImageProcessor.maximumEncodedBytes * 8 / 10
        )
        XCTAssertLessThanOrEqual(
            imageData.count,
            ClipboardImageProcessor.maximumEncodedBytes
        )
        XCTAssertTrue(ClipboardImageProcessor.isDecodableImage(imageData))

        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        storage.save([ClipboardItem(image: image)])
        let writer = StubPasteboardWriter(result: .success)
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults(),
            pasteboardWriter: writer
        )
        let item = try XCTUnwrap(store.items.first)

        ProcessMemoryMetrics.relieveAllocatorPressure()
        let baselineResidentBytes = try ProcessMemoryMetrics.residentSizeBytes()
        let sampler = ProcessResidentPeakSampler(
            baselineResidentBytes: baselineResidentBytes
        )
        sampler.start()
        let start = ContinuousClock.now

        XCTAssertTrue(store.copy(item))

        let elapsed = start.duration(to: .now)
        let peakResidentBytes = sampler.stop()
        let residentGrowth = ProcessMemoryMetrics.positiveGrowth(
            from: baselineResidentBytes,
            to: peakResidentBytes
        )
        XCTAssertLessThan(elapsed, maximumCopyLatency)
        XCTAssertLessThan(
            residentGrowth,
            maximumResidentGrowth,
            "Copy grew resident memory by \(residentGrowth) bytes"
        )
        let request = try XCTUnwrap(writer.requests.first)
        XCTAssertEqual(request.required.map(\.type), [NSPasteboard.PasteboardType.png.rawValue])
        XCTAssertEqual(request.required.first?.value, .data(imageData))
        XCTAssertFalse(
            (request.required + request.optional)
                .contains { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }
        )
    }

    func testSuccessfulImageCaptureClearsOnlyItsCaptureIssue() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        let item = ClipboardItem(text: "paste issue probe")
        let pasteController = makePasteControllerWithPermissionError(
            item: item,
            store: store
        )
        let independentPasteIssue = try XCTUnwrap(pasteController.lastError)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([1, 2, 3]), forType: .png))
        store.pollPasteboardForChanges()
        await waitForState(of: store, "capture warning") { store.captureWarning != nil }
        XCTAssertNotNil(store.captureWarning)

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                try makePNGData(width: 2, height: 2),
                forType: .png
            )
        )
        store.pollPasteboardForChanges()
        await waitForState(of: store, "captured image") { store.items.first?.isImage == true }

        XCTAssertTrue(store.items.first?.isImage == true)
        XCTAssertNil(store.captureWarning)
        XCTAssertEqual(pasteController.lastError, independentPasteIssue)
    }

    func testInvalidImageFallsBackToCapturedTextSnapshot() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([1, 2, 3]), forType: .png))
        XCTAssertTrue(pasteboard.setString("preserve me", forType: .string))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.contentKind, .text)
        XCTAssertEqual(store.items.first?.text, "preserve me")
        XCTAssertNotNil(store.captureWarning)
    }

    func testFailedSpeculativeImageFileFallsBackToTextWithoutWarning() async throws {
        let directory = try makeTemporaryDirectory()
        let storage = ClipboardStorage(appDirectory: directory.appendingPathComponent("Store"))
        let invalidImageURL = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalidImageURL)
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(invalidImageURL.absoluteString, forType: .fileURL))
        XCTAssertTrue(pasteboard.setString("preserve file label", forType: .string))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.first?.text, "preserve file label")
        XCTAssertNil(store.captureWarning)
    }

    func testOversizedImageFallsBackToTheFrozenTextSnapshot() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults(),
            sourceApplicationProvider: { nil }
        )
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                Data(
                    repeating: 0xFF,
                    count: ClipboardImageProcessor.maximumInputBytes + 1
                ),
                forType: .png
            )
        )
        XCTAssertTrue(pasteboard.setString("preserve oversized fallback", forType: .string))

        store.pollPasteboardForChanges()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("later pasteboard value", forType: .string))
        await waitForState(of: store, "oversized fallback") {
            store.items.contains { $0.text == "preserve oversized fallback" }
        }

        let fallback = try XCTUnwrap(
            store.items.first(where: { $0.text == "preserve oversized fallback" })
        )
        XCTAssertEqual(fallback.contentKind, .text)
        XCTAssertEqual(
            store.captureWarning,
            ClipboardImageProcessingError.encodedDataTooLarge.localizedDescription
        )
    }

    func testPollingCapturesJPEGThroughCanonicalImagePipeline() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: makePNGData(width: 3, height: 2)))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                jpeg,
                forType: NSPasteboard.PasteboardType("public.jpeg")
            )
        )

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.first?.contentKind, .image)
        XCTAssertEqual(store.items.first?.image?.width, 3)
        XCTAssertEqual(store.items.first?.image?.height, 2)
    }

    func testPollingCapturesTIFFThroughCanonicalImagePipeline() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: makePNGData(width: 4, height: 3)))
        let tiffData = try XCTUnwrap(bitmap.tiffRepresentation)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(tiffData, forType: .tiff))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        let item = try XCTUnwrap(store.items.first)
        let data = try XCTUnwrap(item.image?.data ?? storage.imageData(for: item))
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(item.image?.width, 4)
        XCTAssertEqual(item.image?.height, 3)
    }

    func testPollingCapturesHEICWhenPlatformEncoderIsAvailable() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(makePNGData(width: 4, height: 3) as CFData, nil)
        )
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let encodedData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encodedData,
                UTType.heic.identifier as CFString,
                1,
                nil
            )
        else {
            throw XCTSkip("The current runner does not provide a HEIC encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("The current runner could not encode the HEIC fixture")
        }
        let heicData = encodedData as Data
        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                heicData,
                forType: NSPasteboard.PasteboardType(UTType.heic.identifier)
            )
        )

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        let item = try XCTUnwrap(store.items.first)
        let data = try XCTUnwrap(item.image?.data ?? storage.imageData(for: item))
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testPNGHasPriorityOverTIFFWhenBothRepresentationsExist() async throws {
        let pasteboard = makePasteboard()
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: storage,
            defaults: makeDefaults()
        )
        let pngData = try makePNGData(width: 2, height: 2)
        let otherBitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 5,
                pixelsHigh: 4,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
        let tiffData = try XCTUnwrap(otherBitmap.tiffRepresentation)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(tiffData, forType: .tiff))
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.first?.image?.width, 2)
        XCTAssertEqual(store.items.first?.image?.height, 2)
    }

    func testPollingCapturesFinderCopiedLocalImageFile() async throws {
        let pasteboard = makePasteboard()
        let store = ClipboardStore(
            pasteboard: pasteboard,
            storage: ClipboardStorage(appDirectory: try makeTemporaryDirectory()),
            defaults: makeDefaults()
        )
        let imageDirectory = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true
        )
        let imageURL = imageDirectory.appendingPathComponent("finder-image.png")
        try makePNGData(width: 5, height: 4).write(to: imageURL)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([imageURL as NSURL]))

        store.pollPasteboardForChanges()
        try await waitForCapturedItem(in: store)

        XCTAssertEqual(store.items.first?.contentKind, .image)
        XCTAssertEqual(store.items.first?.image?.width, 5)
        XCTAssertEqual(store.items.first?.image?.height, 4)
    }

    func testImageDragProviderOffersCanonicalPNGWithoutMutation() throws {
        let storage = ClipboardStorage(appDirectory: try makeTemporaryDirectory())
        let pngData = try makePNGData(width: 2, height: 2)
        storage.save([
            ClipboardItem(
                image: ClipboardImagePayload(data: pngData, width: 2, height: 2)
            )
        ])
        let store = ClipboardStore(
            pasteboard: makePasteboard(),
            storage: storage,
            defaults: makeDefaults()
        )
        let item = try XCTUnwrap(store.items.first)
        let itemsBeforeDrag = store.items
        let provider = store.dragItemProvider(for: item)

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.png.identifier))
        XCTAssertEqual(storage.imageData(for: item), pngData)
        XCTAssertEqual(store.items, itemsBeforeDrag)
        let stager = ClipboardDragFileStager(
            imageReader: storage,
            item: item,
            stagingRoot: try makeTemporaryDirectory(),
            fileManager: .default
        )
        let promisedFileURL = try stager.fileURL()
        XCTAssertTrue(promisedFileURL.isFileURL)
        XCTAssertEqual(promisedFileURL.pathExtension.lowercased(), "png")
        XCTAssertEqual(try Data(contentsOf: promisedFileURL), pngData)
        XCTAssertEqual(store.items.first?.copyCount, 1)
    }
}
