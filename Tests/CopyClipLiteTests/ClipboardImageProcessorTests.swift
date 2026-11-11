import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CopyClipLite

private final class ImageProcessingCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

final class ClipboardImageProcessorTests: XCTestCase {
    func testTruncatedPNGIsRejectedEvenWhenMetadataIsReadable() throws {
        let validPNG = try makePNGData(width: 4, height: 5)
        let truncatedPNG = validPNG.prefix(24)

        XCTAssertThrowsError(
            try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: Data(truncatedPNG), isPNG: true)
            )
        )
    }

    func testOrientationIsNormalizedIntoFullImagePixelsAndDimensions() throws {
        let orientedTIFF = try makeOrientedTIFFData(width: 2, height: 1, orientation: 6)

        let payload = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: orientedTIFF, isPNG: false)
        )

        XCTAssertEqual(payload.width, 1)
        XCTAssertEqual(payload.height, 2)
        let imageData = try XCTUnwrap(payload.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1)
        XCTAssertEqual(image.height, 2)
        XCTAssertNotNil(payload.thumbnailData)
    }

    func testEveryEXIFOrientationProducesMatchingFullAndThumbnailPixels() throws {
        for orientation in 2...8 {
            let orientedTIFF = try makeOrientedTIFFData(
                width: 3,
                height: 2,
                orientation: orientation
            )
            let payload = try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: orientedTIFF, isPNG: false)
            )
            let full = try XCTUnwrap(
                NSBitmapImageRep(data: try XCTUnwrap(payload.data))
            )
            let thumbnail = try XCTUnwrap(
                NSBitmapImageRep(data: try XCTUnwrap(payload.thumbnailData))
            )

            XCTAssertEqual(full.pixelsWide, thumbnail.pixelsWide, "orientation \(orientation)")
            XCTAssertEqual(full.pixelsHigh, thumbnail.pixelsHigh, "orientation \(orientation)")
            XCTAssertEqual(payload.width, full.pixelsWide, "orientation \(orientation)")
            XCTAssertEqual(payload.height, full.pixelsHigh, "orientation \(orientation)")
            for y in 0..<full.pixelsHigh {
                for x in 0..<full.pixelsWide {
                    assertSameColor(
                        full.colorAt(x: x, y: y),
                        thumbnail.colorAt(x: x, y: y),
                        orientation: orientation,
                        x: x,
                        y: y
                    )
                }
            }
        }
    }

    func testJPEGDeclaredAsPNGIsRejected() throws {
        let bitmap = try makeBitmap(width: 3, height: 2)
        let jpeg = try XCTUnwrap(
            bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        )

        XCTAssertThrowsError(
            try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: jpeg, isPNG: true)
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipboardImageProcessingError,
                .invalidImage
            )
        }
    }

    func testInvalidPreferredRepresentationFallsBackToNextValidImage() throws {
        let validTIFF = try makeOrientedTIFFData(width: 3, height: 2, orientation: 1)
        let candidate = ClipboardImageCandidate(
            sources: [
                .data(Data("not a png".utf8), isPNG: true),
                .data(validTIFF, isPNG: false),
            ]
        )

        let payload = try ClipboardImageProcessor.process(candidate)

        XCTAssertEqual(payload.width, 3)
        XCTAssertEqual(payload.height, 2)
        XCTAssertNotNil(payload.data)
        XCTAssertNotNil(payload.thumbnailData)
    }

    func testOversizedFileCandidateIsRejectedBeforeImageDecoding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLite-Oversized-\(UUID().uuidString).png")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ClipboardImageProcessor.maximumInputBytes + 1))
        try handle.close()

        XCTAssertThrowsError(
            try ClipboardImageProcessor.process(
                ClipboardImageCandidate(sources: [.fileURL(url)])
            )
        ) { error in
            XCTAssertEqual(
                error as? ClipboardImageProcessingError,
                .encodedDataTooLarge
            )
        }
    }

    func testMaximumSupportedImageMeetsLatencyAndResidentGrowthBudgets() async throws {
        let side = 4_096
        XCTAssertEqual(side * side, ClipboardImageProcessor.maximumPixelCount)
        let png = try makeSolidPNGData(width: side, height: side)
        let completion = ImageProcessingCompletionFlag()
        let baselineResidentBytes = try residentSize()
        var peakResidentBytes = baselineResidentBytes
        let startedAt = Date()

        let processingTask = Task.detached(priority: .userInitiated) {
            defer { completion.markCompleted() }
            return try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: png, isPNG: true)
            )
        }
        while !completion.isCompleted {
            peakResidentBytes = max(peakResidentBytes, try residentSize())
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let payload = try await processingTask.value
        peakResidentBytes = max(peakResidentBytes, try residentSize())

        XCTAssertEqual(payload.width, side)
        XCTAssertEqual(payload.height, side)
        XCTAssertNotNil(payload.thumbnailData)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        XCTAssertLessThan(
            peakResidentBytes - baselineResidentBytes,
            UInt64(ClipboardImageProcessor.maximumProcessingResidentGrowthBytes)
        )
    }

    func testTwentyFourMegapixelPhotoIsDownscaledIntoOutputBudget() throws {
        let sourceWidth = 6_000
        let sourceHeight = 4_000
        let png = try makeSolidPNGData(width: sourceWidth, height: sourceHeight)

        let payload = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: png, isPNG: true)
        )

        XCTAssertLessThan(payload.width, sourceWidth)
        XCTAssertLessThan(payload.height, sourceHeight)
        XCTAssertLessThanOrEqual(
            payload.width * payload.height,
            ClipboardImageProcessor.maximumPixelCount
        )
        XCTAssertEqual(
            Double(payload.width) / Double(payload.height),
            Double(sourceWidth) / Double(sourceHeight),
            accuracy: 0.001
        )
    }

    func testNoisyPhotoWhosePNGExceedsLimitIsDownscaledUntilItFits() throws {
        let side = 3_072
        let source = try makeNoisyPNGData(side: side)
        XCTAssertLessThanOrEqual(source.count, ClipboardImageProcessor.maximumInputBytes)
        XCTAssertGreaterThan(source.count, ClipboardImageProcessor.maximumEncodedBytes)

        ProcessMemoryMetrics.relieveAllocatorPressure()
        let baseline = try ProcessMemoryMetrics.residentSizeBytes()
        let sampler = ProcessResidentPeakSampler(baselineResidentBytes: baseline)
        sampler.start()
        let payload = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: source, isPNG: true)
        )
        let peak = sampler.stop()

        let data = try XCTUnwrap(payload.data)
        XCTAssertLessThanOrEqual(data.count, ClipboardImageProcessor.maximumEncodedBytes)
        XCTAssertEqual(payload.byteCount, data.count)
        XCTAssertEqual(payload.contentHash, ClipboardImageProcessor.contentHash(for: data))
        XCTAssertLessThan(payload.width, side)
        XCTAssertEqual(payload.width, payload.height)
        XCTAssertGreaterThanOrEqual(payload.width, side / 2)
        XCTAssertNotNil(payload.thumbnailData)
        XCTAssertLessThan(
            ProcessMemoryMetrics.positiveGrowth(from: baseline, to: peak),
            UInt64(ClipboardImageProcessor.maximumProcessingResidentGrowthBytes)
        )

        let reprocessed = try ClipboardImageProcessor.process(
            ClipboardImageCandidate(data: data, isPNG: true)
        )
        XCTAssertEqual(reprocessed.data, data)
        XCTAssertEqual(reprocessed.contentHash, payload.contentHash)
        XCTAssertEqual(reprocessed.width, payload.width)
        XCTAssertEqual(reprocessed.height, payload.height)
    }

    func testReducedOutputDimensionAlwaysShrinksAndTracksOvershoot() {
        let limit = ClipboardImageProcessor.maximumEncodedBytes
        XCTAssertEqual(
            ClipboardImageProcessor.reducedOutputDimension(from: 4_096, encodedByteCount: limit + 1),
            Int((4_096 * 0.9).rounded(.down))
        )
        let reduced = ClipboardImageProcessor.reducedOutputDimension(
            from: 4_096,
            encodedByteCount: limit * 4
        )
        XCTAssertLessThan(reduced, 2_048)
        XCTAssertGreaterThan(reduced, 1_800)
    }

    func testOutputDimensionCalculationPreservesReasonableImagesAndBoundsLargeOnes() {
        XCTAssertEqual(
            ClipboardImageProcessor.maximumOutputDimension(width: 4_000, height: 3_000),
            4_000
        )
        let downscaledMaximum = ClipboardImageProcessor.maximumOutputDimension(
            width: 6_000,
            height: 4_000
        )
        let scale = Double(downscaledMaximum) / 6_000
        XCTAssertLessThanOrEqual(
            Int(6_000 * scale) * Int(4_000 * scale),
            ClipboardImageProcessor.maximumPixelCount
        )
    }

    private func makePNGData(width: Int, height: Int) throws -> Data {
        let bitmap = try makeBitmap(width: width, height: height)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func makeOrientedTIFFData(
        width: Int,
        height: Int,
        orientation: Int
    ) throws -> Data {
        let bitmap = try makeBitmap(width: width, height: height)
        let cgImage = try XCTUnwrap(bitmap.cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.tiff.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(
            destination,
            cgImage,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeSolidPNGData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Low-amplitude deterministic noise: compact enough as a source PNG to stay under
    /// the input limit, but still well over the stored-image limit when re-encoded.
    private func makeNoisyPNGData(side: Int) throws -> Data {
        let bytesPerRow = side * 4
        var pixels = Data(count: bytesPerRow * side)
        pixels.withUnsafeMutableBytes { rawBuffer in
            let words = rawBuffer.bindMemory(to: UInt32.self)
            var state: UInt32 = 0x5EED_1234
            for pixel in 0..<words.count {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                // Little-endian RGBX: three low-entropy colour channels, opaque.
                words[pixel] = 0xFF_A0_80_60 &+ (state & 0x00_07_07_07)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func residentSize() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(
                domain: NSMachErrorDomain,
                code: Int(result)
            )
        }
        return info.resident_size
    }

    private func makeBitmap(width: Int, height: Int) throws -> NSBitmapImageRep {
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
        for y in 0..<height {
            for x in 0..<width {
                bitmap.setColor(
                    x == 0 ? .red : .blue,
                    atX: x,
                    y: y
                )
            }
        }
        return bitmap
    }

    private func assertSameColor(
        _ lhs: NSColor?,
        _ rhs: NSColor?,
        orientation: Int,
        x: Int,
        y: Int
    ) {
        let lhs = lhs?.usingColorSpace(.deviceRGB)
        let rhs = rhs?.usingColorSpace(.deviceRGB)
        XCTAssertNotNil(lhs)
        XCTAssertNotNil(rhs)
        XCTAssertEqual(lhs?.redComponent ?? -1, rhs?.redComponent ?? -2, accuracy: 0.01, "orientation \(orientation), \(x),\(y)")
        XCTAssertEqual(lhs?.greenComponent ?? -1, rhs?.greenComponent ?? -2, accuracy: 0.01, "orientation \(orientation), \(x),\(y)")
        XCTAssertEqual(lhs?.blueComponent ?? -1, rhs?.blueComponent ?? -2, accuracy: 0.01, "orientation \(orientation), \(x),\(y)")
        XCTAssertEqual(lhs?.alphaComponent ?? -1, rhs?.alphaComponent ?? -2, accuracy: 0.01, "orientation \(orientation), \(x),\(y)")
    }
}
