import XCTest
@testable import CopyClipLite

final class TextTransformationTests: XCTestCase {
    func testTitleCaseOnlyUppercasesFirstLetterOfEachWord() {
        XCTAssertEqual(
            TextTransformation.titleCase.applied(to: "macOS API on my iPhone"),
            "MacOS API On My IPhone"
        )
        XCTAssertEqual(
            TextTransformation.titleCase.applied(to: "don't stop\tthe well-known (quick) fox"),
            "Don't Stop\tThe Well-Known (Quick) Fox"
        )
    }
}
