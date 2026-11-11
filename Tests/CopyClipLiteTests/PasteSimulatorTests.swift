import Carbon
import XCTest
@testable import CopyClipLite

final class PasteSimulatorTests: XCTestCase {
    func testQWERTYLayoutUsesANSIVKey() {
        let qwerty: (Int) -> String? = { keyCode in
            switch keyCode {
            case kVK_ANSI_C: return "c"
            case kVK_ANSI_V: return "v"
            case kVK_ANSI_B: return "b"
            default: return nil
            }
        }

        XCTAssertEqual(
            PasteSimulator.pasteKeyCode(layoutLabelProviders: [qwerty]),
            CGKeyCode(kVK_ANSI_V)
        )
    }

    func testDvorakLikeLayoutUsesKeyThatTypesV() {
        let dvorak: (Int) -> String? = { keyCode in
            switch keyCode {
            case kVK_ANSI_V: return "k"
            case kVK_ANSI_Period: return "v"
            default: return nil
            }
        }

        XCTAssertEqual(
            PasteSimulator.pasteKeyCode(layoutLabelProviders: [dvorak]),
            CGKeyCode(kVK_ANSI_Period)
        )
    }

    func testNonLatinLayoutFallsBackToASCIICapableLayout() {
        let cyrillic: (Int) -> String? = { $0 == kVK_ANSI_V ? "м" : nil }
        let asciiDvorak: (Int) -> String? = { $0 == kVK_ANSI_Period ? "v" : nil }

        XCTAssertEqual(
            PasteSimulator.pasteKeyCode(layoutLabelProviders: [cyrillic, asciiDvorak]),
            CGKeyCode(kVK_ANSI_Period)
        )
    }

    func testFallsBackToANSIVWhenNoLayoutTypesV() {
        let cyrillic: (Int) -> String? = { $0 == kVK_ANSI_V ? "м" : nil }

        XCTAssertEqual(
            PasteSimulator.pasteKeyCode(layoutLabelProviders: [cyrillic]),
            CGKeyCode(kVK_ANSI_V)
        )
        XCTAssertEqual(
            PasteSimulator.pasteKeyCode(layoutLabelProviders: []),
            CGKeyCode(kVK_ANSI_V)
        )
    }
}
