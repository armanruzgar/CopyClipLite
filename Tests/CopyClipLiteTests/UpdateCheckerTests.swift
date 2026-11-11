import Foundation
import XCTest
@testable import CopyClipLite

private struct StubUpdateFeedLoader: UpdateFeedLoading {
    let result: Result<CopyClipRelease, Error>

    func latestRelease(from url: URL, userAgent: String) async throws -> CopyClipRelease {
        try result.get()
    }
}

private struct StubUpdateHTTPDataLoader: UpdateHTTPDataLoading, @unchecked Sendable {
    let statusCode: Int
    let data: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
              ) else {
            throw UpdateFeedError.invalidResponse
        }
        return (data, response)
    }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testEquivalentTwoAndThreeComponentVersionsCompareEqual() throws {
        XCTAssertEqual(try XCTUnwrap(CopyClipVersion("1.0")), try XCTUnwrap(CopyClipVersion("1.0.0")))
        XCTAssertEqual(try XCTUnwrap(CopyClipVersion("v2.4")), try XCTUnwrap(CopyClipVersion("2.4.0")))
    }

    func testSemanticVersionComparisonDoesNotUseRawNumericStringOrdering() throws {
        XCTAssertGreaterThan(
            try XCTUnwrap(CopyClipVersion("1.10.0")),
            try XCTUnwrap(CopyClipVersion("1.9.9"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(CopyClipVersion("1.0.9")),
            try XCTUnwrap(CopyClipVersion("1.1.0"))
        )
    }

    func testVersionParserRejectsRepeatedAndTrailingVMarkers() {
        for value in ["vv1.2.3", "VV1.2.3", "vV1.2.3", "1.2.3v", "v1.2.3V"] {
            XCTAssertNil(CopyClipVersion(value), value)
        }
    }

    func testSuccessfulResponseWithNewerVersionReportsAvailableAsset() async throws {
        let assetURL = try XCTUnwrap(
            URL(string: "https://github.com/38st/CopyClipLite/releases/download/v1.2.0/CopyClip-Lite-macOS.zip")
        )
        let checker = try makeHTTPChecker(
            statusCode: 200,
            body: releaseJSON(version: "1.2.0", assetURL: assetURL),
            currentVersion: "1.1.0"
        )

        checker.check()
        await waitUntilNotChecking(checker)

        XCTAssertEqual(checker.state, .updateAvailable(version: "1.2.0", url: assetURL))
    }

    func testSuccessfulResponseWithCurrentVersionReportsUpToDate() async throws {
        let checker = try makeHTTPChecker(
            statusCode: 200,
            body: releaseJSON(version: "1.2.0"),
            currentVersion: "1.2.0"
        )

        checker.check()
        await waitUntilNotChecking(checker)

        XCTAssertEqual(checker.state, .upToDate)
    }

    func testSuccessfulResponseWithOlderVersionReportsUpToDate() async throws {
        let checker = try makeHTTPChecker(
            statusCode: 200,
            body: releaseJSON(version: "1.1.9"),
            currentVersion: "1.2.0"
        )

        checker.check()
        await waitUntilNotChecking(checker)

        XCTAssertEqual(checker.state, .upToDate)
    }

    func testNotFoundResponseReportsInvalidResponse() async throws {
        let checker = try makeHTTPChecker(
            statusCode: 404,
            body: #"{"message":"Not Found"}"#,
            currentVersion: "1.0.0"
        )

        checker.check()
        await waitUntilNotChecking(checker)

        assertFailure(checker, contains: "invalid response")
    }

    func testMalformedJSONReportsInvalidResponse() async throws {
        let checker = try makeHTTPChecker(
            statusCode: 200,
            body: #"{"tag_name":"v1.2.0","assets":"not-an-array"}"#,
            currentVersion: "1.0.0"
        )

        checker.check()
        await waitUntilNotChecking(checker)

        assertFailure(checker, contains: "invalid response")
    }

    func testMalformedReleaseVersionReportsInvalidVersion() async throws {
        let checker = try makeHTTPChecker(
            statusCode: 200,
            body: releaseJSON(version: "not-a-version"),
            currentVersion: "1.0.0"
        )

        checker.check()
        await waitUntilNotChecking(checker)

        assertFailure(checker, contains: "invalid version")
    }

    func testReleaseFeedRejectsRepeatedAndTrailingVMarkers() async throws {
        for version in ["vv1.2.0", "1.2.0v", "v1.2.0V"] {
            let checker = try makeHTTPChecker(
                statusCode: 200,
                body: releaseJSON(version: version),
                currentVersion: "1.0.0"
            )

            checker.check()
            await waitUntilNotChecking(checker)

            assertFailure(checker, contains: "invalid version")
        }
    }

    func testReleaseWithoutMacOSAssetReportsMissingAsset() async throws {
        let checker = try makeHTTPChecker(
            statusCode: 200,
            body: """
            {
              "tag_name": "v1.2.0",
              "assets": [{
                "name": "checksums.txt",
                "browser_download_url": "https://example.com/checksums.txt"
              }]
            }
            """,
            currentVersion: "1.0.0"
        )

        checker.check()
        await waitUntilNotChecking(checker)

        assertFailure(checker, contains: "does not include the macOS app download")
    }

    func testReleaseFeedRejectsUnsafeDownloadURLs() async throws {
        for assetURL in [
            "http://github.com/38st/CopyClipLite/releases/download/v1.2.0/CopyClip-Lite-macOS.zip",
            "https://github.com.example.com/CopyClip-Lite-macOS.zip",
            "https://example.com/CopyClip-Lite-macOS.zip",
        ] {
            let checker = try makeHTTPChecker(
                statusCode: 200,
                body: releaseJSON(
                    version: "1.2.0",
                    assetURL: try XCTUnwrap(URL(string: assetURL))
                ),
                currentVersion: "1.0.0"
            )

            checker.check()
            await waitUntilNotChecking(checker)

            assertFailure(checker, contains: "unsafe download address")
        }
    }

    func testOpenRevalidatesReleaseFromCustomLoader() async throws {
        let unsafeURL = try XCTUnwrap(
            URL(string: "https://example.com/CopyClip-Lite-macOS.zip")
        )
        let checker = UpdateChecker(
            loader: StubUpdateFeedLoader(
                result: .success(CopyClipRelease(version: "2.0.0", url: unsafeURL))
            ),
            feedURL: try XCTUnwrap(URL(string: "https://api.github.com/releases/latest")),
            currentVersion: "1.0.0"
        )
        checker.check()
        await waitUntilNotChecking(checker)
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.0", url: unsafeURL))

        checker.openAvailableUpdate()

        assertFailure(checker, contains: "unsafe download address")
    }

    func testMissingPublicFeedFailsTruthfully() {
        let checker = UpdateChecker(
            loader: StubUpdateFeedLoader(result: .failure(UpdateFeedError.invalidResponse)),
            feedURL: nil,
            currentVersion: "1.0.0"
        )

        checker.check()

        guard case let .failed(message) = checker.state else {
            XCTFail("Expected unavailable state, got \(checker.state)")
            return
        }
        XCTAssertTrue(message.contains("No public update channel"))
    }

    private func waitUntilNotChecking(_ checker: UpdateChecker) async {
        await checker.checkTask?.value
        XCTAssertNotEqual(checker.state, .checking)
    }

    private func makeHTTPChecker(
        statusCode: Int,
        body: String,
        currentVersion: String
    ) throws -> UpdateChecker {
        UpdateChecker(
            loader: GitHubUpdateFeedLoader(
                httpLoader: StubUpdateHTTPDataLoader(
                    statusCode: statusCode,
                    data: Data(body.utf8)
                )
            ),
            feedURL: try XCTUnwrap(URL(string: "https://example.com/releases/latest")),
            currentVersion: currentVersion
        )
    }

    private func releaseJSON(
        version: String,
        assetURL: URL? = nil
    ) -> String {
        let assetURL = assetURL?.absoluteString
            ?? "https://github.com/38st/CopyClipLite/releases/download/v\(version)/CopyClip-Lite-macOS.zip"
        return """
        {
          "tag_name": "v\(version)",
          "assets": [{
            "name": "CopyClip-Lite-macOS.zip",
            "browser_download_url": "\(assetURL)"
          }]
        }
        """
    }

    private func assertFailure(
        _ checker: UpdateChecker,
        contains expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failed(message) = checker.state else {
            XCTFail("Expected failed state, got \(checker.state)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains(expectedText),
            "Expected “\(message)” to contain “\(expectedText)”",
            file: file,
            line: line
        )
    }
}
