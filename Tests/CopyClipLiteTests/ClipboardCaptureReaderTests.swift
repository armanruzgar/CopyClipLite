import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CopyClipLite

final class ClipboardCaptureReaderTests: XCTestCase {
    func testOversizedRichTextIsNotParsedAndItsWarningIsPreserved() throws {
        let pasteboard = makePasteboard()
        let oversizedRTF = Data(
            repeating: 0x41,
            count: ClipboardStorage.maximumImportedRichTextBytes + 1
        )
        pasteboard.setData(oversizedRTF, forType: .rtf)

        let result = ClipboardCaptureReader.text(from: pasteboard)

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(
            result.warning,
            "The text was saved without oversized RTF formatting."
        )
    }

    func testInvalidPNGRepresentationFallsBackToValidTIFF() throws {
        let pasteboard = makePasteboard()
        pasteboard.setData(Data("not a png".utf8), forType: .png)
        pasteboard.setData(try makeTIFFData(width: 4, height: 3), forType: .tiff)

        let candidate = try XCTUnwrap(ClipboardCaptureReader.image(from: pasteboard))
        let payload = try ClipboardImageProcessor.process(candidate)

        XCTAssertEqual(payload.width, 4)
        XCTAssertEqual(payload.height, 3)
    }

    func testFinderImageFileURLIsSnapshottedWithoutReadingTheFile() throws {
        let pasteboard = makePasteboard()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLite-Missing-\(UUID().uuidString).png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        pasteboard.setString(missingURL.absoluteString, forType: .fileURL)

        let candidate = try XCTUnwrap(ClipboardCaptureReader.image(from: pasteboard))

        guard case let .fileURL(snapshotURL) = try XCTUnwrap(candidate.sources.first) else {
            return XCTFail("Expected a deferred file URL candidate")
        }
        XCTAssertEqual(snapshotURL, missingURL)
    }

    func testFinderNonImageFileURLIsNotTreatedAsAnImageCandidate() {
        let pasteboard = makePasteboard()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLite-Missing-\(UUID().uuidString).txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        pasteboard.setString(missingURL.absoluteString, forType: .fileURL)

        XCTAssertNil(ClipboardCaptureReader.image(from: pasteboard))
    }

    func testEveryFinderFileURLIsReadAndNoneGoesToTheImagePipeline() {
        let pasteboard = makePasteboard()
        let directory = FileManager.default.temporaryDirectory
        let urls = ["a.txt", "b.png", "c.pdf"].map {
            directory.appendingPathComponent("CopyClipLite-\(UUID().uuidString)-\($0)")
        }
        pasteboard.setItemStrings(urls.map(\.absoluteString), forType: .fileURL)

        XCTAssertEqual(ClipboardCaptureReader.fileURLs(from: pasteboard).map(\.path), urls.map(\.path))
        XCTAssertNil(ClipboardCaptureReader.image(from: pasteboard))
        XCTAssertNil(ClipboardCaptureReader.link(from: pasteboard))
    }

    func testFileReferenceURLIsNormalisedToItsPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopyClipLite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("Quarterly Report.txt")
        try Data("report".utf8).write(to: fileURL)
        // Bridging to URL resolves the reference, so keep the NSURL to get Finder's form.
        let referenceURL = try XCTUnwrap(
            (fileURL as NSURL).perform(#selector(NSURL.fileReferenceURL))?
                .takeUnretainedValue() as? NSURL
        )
        let referenceString = try XCTUnwrap(referenceURL.absoluteString)
        XCTAssertTrue(referenceString.contains("/.file/id="))
        let pasteboard = makePasteboard()
        pasteboard.setString(referenceString, forType: .fileURL)

        let link = try XCTUnwrap(ClipboardCaptureReader.link(from: pasteboard))

        XCTAssertEqual(link.title, "Quarterly Report.txt")
        XCTAssertEqual(
            link.url.resolvingSymlinksInPath().path,
            fileURL.resolvingSymlinksInPath().path
        )
    }

    func testWebLinkTitleIsReadFromURLName() throws {
        let urlName = NSPasteboard.PasteboardType("public.url-name")
        let pasteboard = makePasteboard()
        pasteboard.setString("https://example.com/article", forType: .URL)
        pasteboard.setString("  An Example Article \n", forType: urlName)

        XCTAssertEqual(ClipboardCaptureReader.link(from: pasteboard)?.title, "An Example Article")

        pasteboard.setString("https://example.com/article", forType: urlName)
        let untitled = try XCTUnwrap(ClipboardCaptureReader.link(from: pasteboard))
        XCTAssertNil(untitled.title)

        pasteboard.setString("   ", forType: urlName)
        XCTAssertNil(ClipboardCaptureReader.link(from: pasteboard)?.title)
    }

    func testHTMLOnlyClipboardIsReadLocallyWithoutScriptsOrStyles() throws {
        let pasteboard = makePasteboard()
        let html = """
        <html><head><title>Ignored</title><style>p { color: red; }</style></head>
        <body><script>document.write("nope")</script><!-- note -->
        <p>Fish &amp; Chips&nbsp;&#x2014; <img src="https://example.invalid/x.png">today</p>
        <p>Second&#33; &lt;b&gt;</p></body></html>
        """
        pasteboard.setData(Data(html.utf8), forType: .html)

        let snapshot = try XCTUnwrap(ClipboardCaptureReader.text(from: pasteboard).snapshot)

        XCTAssertEqual(snapshot.text, "Fish & Chips — today\nSecond! <b>")
        XCTAssertEqual(snapshot.htmlData, Data(html.utf8))
        XCTAssertEqual(
            ClipboardHTMLTextExtractor.plainText(
                fromHTML: "<table><tr><td>A</td><td>B</td></tr></table>Mid<b>word</b>"
            ),
            "A B\nMidword"
        )
    }

    private func makePasteboard() -> StubCapturePasteboard {
        StubCapturePasteboard()
    }

    private func makeTIFFData(width: Int, height: Int) throws -> Data {
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
                UTType.tiff.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class StubCapturePasteboard: ClipboardCapturePasteboard {
    private var values: [NSPasteboard.PasteboardType: Data] = [:]
    private var itemValues: [NSPasteboard.PasteboardType: [String]] = [:]

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        values[dataType]
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        values[dataType].flatMap { String(data: $0, encoding: .utf8) }
    }

    func itemStrings(forType dataType: NSPasteboard.PasteboardType) -> [String] {
        itemValues[dataType] ?? string(forType: dataType).map { [$0] } ?? []
    }

    func setData(_ data: Data, forType dataType: NSPasteboard.PasteboardType) {
        values[dataType] = data
        itemValues[dataType] = nil
    }

    func setItemStrings(_ strings: [String], forType dataType: NSPasteboard.PasteboardType) {
        values[dataType] = strings.first.map { Data($0.utf8) }
        itemValues[dataType] = strings
    }

    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) {
        setData(Data(string.utf8), forType: dataType)
    }
}
