import Carbon
import Foundation
import XCTest
@testable import CopyClipLite

final class HotkeyConfigMigrationTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = makeIsolatedDefaults()
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    func testDefaultIsControlOptionVAndPassesValidation() {
        XCTAssertEqual(
            HotkeyConfig.default,
            HotkeyConfig(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey)
        )
        XCTAssertEqual(
            HotkeyConfig.default.displayString(layoutLabelProvider: { _ in nil }),
            "⌃⌥V"
        )
        XCTAssertNil(HotkeyConfig.default.validationError)
        XCTAssertNil(HotkeyConfig.legacyDefault.validationError)
        XCTAssertEqual(
            HotkeyConfig.legacyDefault,
            HotkeyConfig(keyCode: kVK_ANSI_V, modifiers: cmdKey | optionKey)
        )
    }

    func testNewInstallGetsNewDefault() {
        HotkeyConfig.migrateLegacyDefaultIfNeeded(in: defaults)

        XCTAssertNil(defaults.data(forKey: HotkeyConfig.DefaultsKey.hotkeyConfig))
        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)
    }

    func testNewInstallStaysOnNewDefaultAfterCompletingWelcome() {
        HotkeyConfig.migrateLegacyDefaultIfNeeded(in: defaults)
        defaults.set(true, forKey: HotkeyConfig.DefaultsKey.hasCompletedWelcome)

        HotkeyConfig.migrateLegacyDefaultIfNeeded(in: defaults)

        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)
    }

    func testExistingUserWithoutSavedConfigKeepsLegacyDefault() {
        defaults.set(true, forKey: HotkeyConfig.DefaultsKey.hasCompletedWelcome)

        HotkeyConfig.migrateLegacyDefaultIfNeeded(in: defaults)

        XCTAssertEqual(HotkeyConfig.load(from: defaults), .legacyDefault)
    }

    func testExistingUserWithInvalidSavedConfigKeepsLegacyDefault() throws {
        defaults.set(true, forKey: HotkeyConfig.DefaultsKey.hasCompletedWelcome)
        let invalid = HotkeyConfig(keyCode: -1, modifiers: cmdKey)
        defaults.set(
            try JSONEncoder().encode(invalid),
            forKey: HotkeyConfig.DefaultsKey.hotkeyConfig
        )

        HotkeyConfig.migrateLegacyDefaultIfNeeded(in: defaults)

        XCTAssertEqual(HotkeyConfig.load(from: defaults), .legacyDefault)
    }

    func testExistingUserWithCustomConfigIsUntouched() {
        defaults.set(true, forKey: HotkeyConfig.DefaultsKey.hasCompletedWelcome)
        let custom = HotkeyConfig(keyCode: kVK_ANSI_K, modifiers: cmdKey | controlKey)
        custom.save(to: defaults)
        let savedData = defaults.data(forKey: HotkeyConfig.DefaultsKey.hotkeyConfig)

        HotkeyConfig.migrateLegacyDefaultIfNeeded(in: defaults)

        XCTAssertEqual(defaults.data(forKey: HotkeyConfig.DefaultsKey.hotkeyConfig), savedData)
        XCTAssertEqual(HotkeyConfig.load(from: defaults), custom)
    }

    func testMigrationRunsOnlyOnce() {
        defaults.set(true, forKey: HotkeyConfig.DefaultsKey.hasCompletedWelcome)
        HotkeyConfig.migrateLegacyDefaultIfNeeded(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: HotkeyConfig.DefaultsKey.didMigrateLegacyDefault))

        defaults.removeObject(forKey: HotkeyConfig.DefaultsKey.hotkeyConfig)
        HotkeyConfig.migrateLegacyDefaultIfNeeded(in: defaults)

        XCTAssertNil(defaults.data(forKey: HotkeyConfig.DefaultsKey.hotkeyConfig))
        XCTAssertEqual(HotkeyConfig.load(from: defaults), .default)
    }
}
