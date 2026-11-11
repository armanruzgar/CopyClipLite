import Carbon
import Foundation
import XCTest
@testable import CopyClipLite

@MainActor
private final class FakeHotkeyRegistrar: GlobalHotkeyRegistering {
    var isRegistered = false
    var activeConfig: HotkeyConfig?
    var installResult: Result<Void, GlobalHotkeyRegistrationError> = .success(())
    var nextRegistrationResult: Result<Void, GlobalHotkeyRegistrationError> = .success(())
    var registrationAttempts: [HotkeyConfig] = []
    var didSuspend = false
    var action: (@MainActor @Sendable () -> Void)?

    func installHandler(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, GlobalHotkeyRegistrationError> {
        self.action = action
        return installResult
    }

    func replace(with config: HotkeyConfig) -> Result<Void, GlobalHotkeyRegistrationError> {
        registrationAttempts.append(config)
        switch nextRegistrationResult {
        case .success:
            activeConfig = config
            isRegistered = true
            didSuspend = false
            return .success(())
        case let .failure(error):
            return .failure(error)
        }
    }

    func suspend() {
        didSuspend = true
        isRegistered = false
    }

    func resume() -> Result<Void, GlobalHotkeyRegistrationError> {
        guard didSuspend, let activeConfig else {
            return .success(())
        }
        return replace(with: activeConfig)
    }
}

@MainActor
final class GlobalHotkeyControllerTests: XCTestCase {
    func testShiftOnlyShortcutIsRejected() {
        let config = HotkeyConfig(keyCode: kVK_ANSI_A, modifiers: shiftKey)

        XCTAssertEqual(config.validationError, .unsafeModifierCombination)
    }

    func testSingleModifierEditingShortcutIsRejectedButMultiModifierShortcutIsAccepted() {
        XCTAssertEqual(
            HotkeyConfig(keyCode: kVK_ANSI_V, modifiers: cmdKey).validationError,
            .unsafeEditingShortcut
        )
        XCTAssertEqual(
            HotkeyConfig(keyCode: kVK_LeftArrow, modifiers: optionKey).validationError,
            .unsafeEditingShortcut
        )
        XCTAssertNil(
            HotkeyConfig(
                keyCode: kVK_ANSI_V,
                modifiers: cmdKey | optionKey
            ).validationError
        )
        XCTAssertNil(
            HotkeyConfig(keyCode: kVK_F12, modifiers: controlKey).validationError
        )
    }

    func testStandardMultiModifierEditingAndSystemShortcutsAreRejectedSpecifically() {
        let unsafeShortcuts = [
            HotkeyConfig(
                keyCode: kVK_ANSI_V,
                modifiers: cmdKey | optionKey | shiftKey
            ),
            HotkeyConfig(keyCode: kVK_Escape, modifiers: cmdKey | optionKey),
            HotkeyConfig(keyCode: kVK_ANSI_Q, modifiers: cmdKey | controlKey),
            HotkeyConfig(keyCode: kVK_Space, modifiers: cmdKey | controlKey),
            HotkeyConfig(keyCode: kVK_ANSI_F, modifiers: cmdKey | controlKey),
            HotkeyConfig(keyCode: kVK_ANSI_D, modifiers: cmdKey | optionKey),
            HotkeyConfig(keyCode: kVK_ANSI_H, modifiers: cmdKey | optionKey),
            HotkeyConfig(keyCode: kVK_ANSI_M, modifiers: cmdKey | optionKey),
            HotkeyConfig(keyCode: kVK_Space, modifiers: cmdKey | optionKey),
        ]

        for shortcut in unsafeShortcuts {
            XCTAssertEqual(
                shortcut.validationError,
                .unsafeSystemShortcut,
                shortcut.displayString
            )
            XCTAssertEqual(
                shortcut.validationError?.localizedDescription,
                "Choose a shortcut that does not replace a standard editing or macOS system command."
            )
        }
    }

    func testMultiModifierSafetyRulesDoNotOverblockNearbyShortcuts() {
        let safeShortcuts = [
            HotkeyConfig.default,
            HotkeyConfig.legacyDefault,
            HotkeyConfig(keyCode: kVK_ANSI_B, modifiers: cmdKey | optionKey),
            HotkeyConfig(keyCode: kVK_ANSI_K, modifiers: cmdKey | controlKey),
            HotkeyConfig(
                keyCode: kVK_ANSI_B,
                modifiers: cmdKey | optionKey | shiftKey
            ),
            HotkeyConfig(keyCode: kVK_F12, modifiers: cmdKey | optionKey),
        ]

        for shortcut in safeShortcuts {
            XCTAssertNil(shortcut.validationError, shortcut.displayString)
        }
    }

    func testInjectedNonUSLayoutLabelsPreserveDeterministicModifierOrder() {
        let config = HotkeyConfig(
            keyCode: kVK_ANSI_Q,
            modifiers: controlKey | optionKey | shiftKey | cmdKey
        )
        var requestedKeyCodes: [Int] = []

        let displayString = config.displayString { keyCode in
            requestedKeyCodes.append(keyCode)
            return "a"
        }

        XCTAssertEqual(requestedKeyCodes, [kVK_ANSI_Q])
        XCTAssertEqual(displayString, "⌃⌥⇧⌘A")
    }

    func testInjectedLayoutLabelFallsBackForWhitespaceOrControlCharacters() {
        let config = HotkeyConfig(
            keyCode: kVK_ANSI_Q,
            modifiers: cmdKey | optionKey
        )

        XCTAssertEqual(
            config.displayString(layoutLabelProvider: { _ in " " }),
            "⌥⌘Q"
        )
        XCTAssertEqual(
            config.displayString(layoutLabelProvider: { _ in "\n" }),
            "⌥⌘Q"
        )
    }

    func testInvalidPersistedShortcutFallsBackToDefault() throws {
        let defaults = makeIsolatedDefaults()
        let invalid = HotkeyConfig(keyCode: -1, modifiers: cmdKey)
        defaults.set(try JSONEncoder().encode(invalid), forKey: HotkeyConfig.DefaultsKey.hotkeyConfig)

        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)
    }

    func testFailedReplacementKeepsPreviousRegistrationAndConfig() {
        let registrar = FakeHotkeyRegistrar()
        let controller = GlobalHotkeyController(config: .default, registrar: registrar)
        let attempted = HotkeyConfig(keyCode: kVK_ANSI_B, modifiers: cmdKey | optionKey)
        registrar.nextRegistrationResult = .failure(
            .registration(OSStatus(eventHotKeyExistsErr), shortcut: attempted.displayString)
        )

        controller.updateConfig(attempted)

        XCTAssertEqual(controller.config, .default)
        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(registrar.activeConfig, .default)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testReapplyingRegisteredConfigIsNoOpAndClearsPreviousError() {
        let registrar = FakeHotkeyRegistrar()
        let controller = GlobalHotkeyController(config: .default, registrar: registrar)
        let attempted = HotkeyConfig(keyCode: kVK_ANSI_B, modifiers: cmdKey | optionKey)
        registrar.nextRegistrationResult = .failure(
            .registration(OSStatus(eventHotKeyExistsErr), shortcut: attempted.displayString)
        )
        controller.updateConfig(attempted)
        let attemptsAfterFailure = registrar.registrationAttempts.count

        controller.updateConfig(.default)

        XCTAssertEqual(registrar.registrationAttempts.count, attemptsAfterFailure)
        XCTAssertTrue(controller.isRegistered)
        XCTAssertNil(controller.errorMessage)
    }

    func testReapplyingCurrentConfigRetriesWhenRegistrationIsMissing() {
        let registrar = FakeHotkeyRegistrar()
        let controller = GlobalHotkeyController(config: .default, registrar: registrar)
        let initialAttemptCount = registrar.registrationAttempts.count
        registrar.isRegistered = false

        controller.updateConfig(.default)

        XCTAssertEqual(registrar.registrationAttempts.count, initialAttemptCount + 1)
        XCTAssertTrue(controller.isRegistered)
    }

    func testSuccessfulReplacementAndResetEachRegisterExactlyOnce() {
        let registrar = FakeHotkeyRegistrar()
        let controller = GlobalHotkeyController(config: .default, registrar: registrar)
        let replacement = HotkeyConfig(
            keyCode: kVK_ANSI_B,
            modifiers: cmdKey | controlKey
        )
        let initialAttemptCount = registrar.registrationAttempts.count

        controller.updateConfig(replacement)

        XCTAssertEqual(controller.config, replacement)
        XCTAssertEqual(
            registrar.registrationAttempts.count,
            initialAttemptCount + 1
        )

        controller.updateConfig(.default)

        XCTAssertEqual(controller.config, .default)
        XCTAssertEqual(
            registrar.registrationAttempts.count,
            initialAttemptCount + 2
        )
    }

    func testHandlerFailurePreventsRegistration() {
        let registrar = FakeHotkeyRegistrar()
        registrar.installResult = .failure(.handler(-1))

        let controller = GlobalHotkeyController(config: .default, registrar: registrar)

        XCTAssertFalse(controller.isRegistered)
        XCTAssertTrue(registrar.registrationAttempts.isEmpty)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testRecordingSuspendsAndRestoresCurrentShortcut() {
        let registrar = FakeHotkeyRegistrar()
        let controller = GlobalHotkeyController(config: .default, registrar: registrar)

        controller.setRecording(true)

        XCTAssertFalse(controller.isRegistered)
        XCTAssertTrue(registrar.didSuspend)

        controller.setRecording(false)

        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(registrar.activeConfig, .default)
    }

    func testSuccessfulRecordingResumeClearsPreviousError() {
        let registrar = FakeHotkeyRegistrar()
        let controller = GlobalHotkeyController(config: .default, registrar: registrar)
        let attempted = HotkeyConfig(keyCode: kVK_ANSI_B, modifiers: cmdKey | optionKey)
        registrar.nextRegistrationResult = .failure(
            .registration(OSStatus(eventHotKeyExistsErr), shortcut: attempted.displayString)
        )
        controller.updateConfig(attempted)
        XCTAssertNotNil(controller.errorMessage)

        controller.setRecording(true)
        registrar.nextRegistrationResult = .success(())
        controller.setRecording(false)

        XCTAssertTrue(controller.isRegistered)
        XCTAssertNil(controller.errorMessage)
    }

    func testRepeatedInjectedRegistrarLifecycleDoesNotCreateRetainCycles() {
        for _ in 0..<100 {
            weak var releasedController: GlobalHotkeyController?
            weak var releasedRegistrar: FakeHotkeyRegistrar?

            autoreleasepool {
                let registrar = FakeHotkeyRegistrar()
                var controller: GlobalHotkeyController? = GlobalHotkeyController(
                    config: .default,
                    registrar: registrar
                )
                releasedController = controller
                releasedRegistrar = registrar
                XCTAssertTrue(controller?.isRegistered == true)
                controller = nil
            }

            XCTAssertNil(releasedController)
            XCTAssertNil(releasedRegistrar)
        }
    }
}
