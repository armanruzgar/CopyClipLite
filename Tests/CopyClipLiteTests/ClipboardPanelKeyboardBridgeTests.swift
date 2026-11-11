import AppKit
import Carbon
import XCTest
@testable import CopyClipLite

@MainActor
final class ClipboardPanelKeyboardBridgeTests: XCTestCase {
    func testRealEventsRespectSearchFieldEditorAndExplicitCommands() throws {
        let fieldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        fieldEditor.string = "search query"
        var actions: [ClipboardPanelKeyAction] = []
        let handle: (NSEvent) -> Bool = { event in
            ClipboardPanelKeyRouting.handle(
                event,
                firstResponder: fieldEditor
            ) { action in
                actions.append(action)
                return true
            }
        }

        let unmodifiedPin = try keyEvent(
            keyCode: UInt16(kVK_ANSI_P),
            characters: "p"
        )
        XCTAssertFalse(handle(unmodifiedPin))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(fieldEditor.string, "search query")

        let explicitPin = try keyEvent(
            keyCode: UInt16(kVK_ANSI_P),
            characters: "p",
            modifiers: .command
        )
        XCTAssertTrue(handle(explicitPin))
        XCTAssertEqual(actions, [.togglePinSelected])
        XCTAssertEqual(fieldEditor.string, "search query")

        let unmodifiedDelete = try keyEvent(
            keyCode: UInt16(kVK_Delete),
            characters: "\u{8}"
        )
        XCTAssertFalse(handle(unmodifiedDelete))
        XCTAssertEqual(actions, [.togglePinSelected])
        XCTAssertEqual(fieldEditor.string, "search query")

        let explicitDelete = try keyEvent(
            keyCode: UInt16(kVK_Delete),
            characters: "\u{8}",
            modifiers: .command
        )
        XCTAssertFalse(handle(explicitDelete))
        XCTAssertEqual(actions, [.togglePinSelected])
        XCTAssertEqual(fieldEditor.string, "search query")

        fieldEditor.string = ""
        XCTAssertTrue(handle(explicitDelete))
        XCTAssertEqual(actions, [.togglePinSelected, .deleteSelected])
    }

    func testCommandDeleteFallsThroughToTextEditorWithText() {
        for keyCode in [UInt16(kVK_Delete), UInt16(kVK_ForwardDelete)] {
            XCTAssertNil(
                ClipboardPanelKeyRouting.action(
                    for: input(
                        keyCode: keyCode,
                        modifiers: .command,
                        isEditingText: true,
                        editorHasText: true
                    )
                )
            )
            XCTAssertEqual(
                ClipboardPanelKeyRouting.action(
                    for: input(
                        keyCode: keyCode,
                        modifiers: .command,
                        isEditingText: true
                    )
                ),
                .deleteSelected
            )
            XCTAssertEqual(
                ClipboardPanelKeyRouting.action(
                    for: input(keyCode: keyCode, modifiers: .command)
                ),
                .deleteSelected
            )
        }

        XCTAssertEqual(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_P),
                    characters: "p",
                    modifiers: .command,
                    isEditingText: true,
                    editorHasText: true
                )
            ),
            .togglePinSelected
        )
    }

    func testRealCommandFEventWithCapsLockIsConsumedWhileSearchIsFirstResponder() throws {
        let fieldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let event = try keyEvent(
            keyCode: UInt16(kVK_ANSI_F),
            characters: "F",
            modifiers: [.command, .capsLock, .numericPad, .function]
        )
        var actions: [ClipboardPanelKeyAction] = []

        XCTAssertTrue(
            ClipboardPanelKeyRouting.handle(event, firstResponder: fieldEditor) { action in
                actions.append(action)
                return true
            }
        )
        XCTAssertEqual(actions, [.focusSearch])
    }

    func testRoutesEverySupportedKeyVariant() {
        let cases: [(UInt16, String?, NSEvent.ModifierFlags, ClipboardPanelKeyAction)] = [
            (UInt16(kVK_DownArrow), nil, [], .moveDown),
            (UInt16(kVK_UpArrow), nil, [], .moveUp),
            (UInt16(kVK_Return), nil, [], .copySelected),
            (UInt16(kVK_ANSI_KeypadEnter), nil, [], .copySelected),
            (UInt16(kVK_ANSI_F), "f", .command, .focusSearch),
            (UInt16(kVK_ANSI_P), "p", .command, .togglePinSelected),
            (UInt16(kVK_ANSI_V), "v", [.command, .shift], .copySelectedWithoutFormatting),
            (UInt16(kVK_ANSI_1), "1", .command, .quickSelect(1)),
            (UInt16(kVK_ANSI_9), "9", .command, .quickSelect(9)),
            (UInt16(kVK_Delete), nil, .command, .deleteSelected),
            (UInt16(kVK_ForwardDelete), nil, .command, .deleteSelected),
        ]

        for (keyCode, characters, modifiers, expectedAction) in cases {
            let action = ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: keyCode,
                    characters: characters,
                    modifiers: modifiers
                )
            )

            XCTAssertEqual(
                action,
                expectedAction,
                "Unexpected action for keyCode \(keyCode), modifiers \(modifiers)"
            )
        }
    }

    func testTextEditingExcludesUnmodifiedPinAndDelete() {
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_P),
                    characters: "p",
                    isEditingText: true
                )
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(keyCode: UInt16(kVK_Delete), isEditingText: true)
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(keyCode: UInt16(kVK_ForwardDelete), isEditingText: true)
            )
        )
    }

    func testUnmodifiedPinAndDeleteAreNotPanelCommandsOutsideTextEditing() {
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(keyCode: UInt16(kVK_ANSI_P), characters: "p")
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(keyCode: UInt16(kVK_Delete))
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(keyCode: UInt16(kVK_ForwardDelete))
            )
        )
    }

    func testTextEditingStillAllowsListNavigationUseAndExplicitCommands() {
        let cases: [(UInt16, String?, NSEvent.ModifierFlags, ClipboardPanelKeyAction)] = [
            (UInt16(kVK_DownArrow), nil, [], .moveDown),
            (UInt16(kVK_UpArrow), nil, [], .moveUp),
            (UInt16(kVK_Return), nil, [], .copySelected),
            (UInt16(kVK_ANSI_KeypadEnter), nil, [], .copySelected),
            (UInt16(kVK_ANSI_P), "p", .command, .togglePinSelected),
            (UInt16(kVK_Delete), nil, .command, .deleteSelected),
            (UInt16(kVK_ForwardDelete), nil, .command, .deleteSelected),
            (UInt16(kVK_ANSI_F), "f", .command, .focusSearch),
            (UInt16(kVK_ANSI_1), "1", .command, .quickSelect(1)),
            (UInt16(kVK_ANSI_V), "v", [.command, .shift], .copySelectedWithoutFormatting),
        ]

        for (keyCode, characters, modifiers, expectedAction) in cases {
            XCTAssertEqual(
                ClipboardPanelKeyRouting.action(
                    for: input(
                        keyCode: keyCode,
                        characters: characters,
                        modifiers: modifiers,
                        isEditingText: true
                    )
                ),
                expectedAction
            )
        }
    }

    func testFocusedNonTextControlKeepsStandardUnmodifiedKeys() throws {
        let button = NSButton(title: "Clear", target: nil, action: nil)
        let cases: [(UInt16, String?)] = [
            (UInt16(kVK_DownArrow), nil),
            (UInt16(kVK_UpArrow), nil),
            (UInt16(kVK_Return), nil),
            (UInt16(kVK_ANSI_KeypadEnter), nil),
            (UInt16(kVK_Delete), nil),
            (UInt16(kVK_ForwardDelete), nil),
            (UInt16(kVK_ANSI_P), "p"),
        ]

        for (keyCode, characters) in cases {
            let event = try keyEvent(
                keyCode: keyCode,
                characters: characters ?? ""
            )
            XCTAssertNil(
                ClipboardPanelKeyRouting.action(
                    for: event,
                    firstResponder: button
                )
            )
        }
    }

    func testFocusedNonTextControlStillAllowsDocumentedCommandShortcuts() throws {
        let button = NSButton(title: "Clear", target: nil, action: nil)
        let cases: [(UInt16, String, ClipboardPanelKeyAction)] = [
            (UInt16(kVK_ANSI_F), "f", .focusSearch),
            (UInt16(kVK_ANSI_P), "p", .togglePinSelected),
            (UInt16(kVK_ANSI_1), "1", .quickSelect(1)),
            (UInt16(kVK_Delete), "\u{8}", .deleteSelected),
        ]

        for (keyCode, characters, expectedAction) in cases {
            let event = try keyEvent(
                keyCode: keyCode,
                characters: characters,
                modifiers: .command
            )
            XCTAssertEqual(
                ClipboardPanelKeyRouting.action(
                    for: event,
                    firstResponder: button
                ),
                expectedAction
            )
        }
    }

    func testIgnoresCapsLockNumericPadAndFunctionForCommandShortcuts() {
        let irrelevantFlags: NSEvent.ModifierFlags = [
            .capsLock,
            .numericPad,
            .function,
        ]

        XCTAssertEqual(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_F),
                    characters: "F",
                    modifiers: [.command, irrelevantFlags]
                )
            ),
            .focusSearch
        )
        XCTAssertEqual(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_P),
                    characters: "P",
                    modifiers: [.command, irrelevantFlags],
                    isEditingText: true
                )
            ),
            .togglePinSelected
        )
    }

    func testRejectsUnsupportedModifiersAndUnknownKeys() {
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_F),
                    characters: "f",
                    modifiers: [.command, .shift]
                )
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_0),
                    characters: "0",
                    modifiers: .command
                )
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(
                    keyCode: UInt16(kVK_ANSI_P),
                    characters: "p",
                    modifiers: .option
                )
            )
        )
        XCTAssertNil(
            ClipboardPanelKeyRouting.action(
                for: input(keyCode: UInt16(kVK_ANSI_A), characters: "a")
            )
        )
    }

    func testHandledReturnMatchesHandlerAndUnhandledEventsPropagate() {
        let recognized = input(keyCode: UInt16(kVK_DownArrow))
        var receivedActions: [ClipboardPanelKeyAction] = []

        XCTAssertTrue(
            ClipboardPanelKeyRouting.handle(recognized) { action in
                receivedActions.append(action)
                return true
            }
        )
        XCTAssertEqual(receivedActions, [.moveDown])

        XCTAssertFalse(
            ClipboardPanelKeyRouting.handle(recognized) { action in
                receivedActions.append(action)
                return false
            }
        )
        XCTAssertEqual(receivedActions, [.moveDown, .moveDown])

        let unknown = input(keyCode: UInt16(kVK_ANSI_A), characters: "a")
        XCTAssertFalse(
            ClipboardPanelKeyRouting.handle(unknown) { _ in
                XCTFail("An unrecognized event must not invoke the action handler")
                return true
            }
        )
    }

    private func input(
        keyCode: UInt16,
        characters: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        isEditingText: Bool = false,
        editorHasText: Bool = false,
        preservesFocusedControlKeys: Bool = false
    ) -> ClipboardPanelKeyInput {
        ClipboardPanelKeyInput(
            keyCode: keyCode,
            charactersIgnoringModifiers: characters,
            modifierFlags: modifiers,
            focusContext: preservesFocusedControlKeys
                ? .control
                : (isEditingText ? .textEditor(hasText: editorHasText) : .list)
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}
