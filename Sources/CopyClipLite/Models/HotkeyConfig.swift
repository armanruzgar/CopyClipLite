import AppKit
import Carbon
import Foundation

enum HotkeyConfigValidationError: LocalizedError, Equatable {
    case keyCodeOutOfRange
    case unsupportedModifiers
    case unsafeModifierCombination
    case unsafeEditingShortcut
    case unsafeSystemShortcut

    var errorDescription: String? {
        switch self {
        case .keyCodeOutOfRange:
            return "Choose a supported keyboard key."
        case .unsupportedModifiers:
            return "The shortcut contains unsupported modifier keys."
        case .unsafeModifierCombination:
            return "Use Command, Option, or Control. Shift cannot be the only modifier."
        case .unsafeEditingShortcut:
            return "Add a second Command, Option, or Control modifier so the shortcut does not replace normal typing or editing."
        case .unsafeSystemShortcut:
            return "Choose a shortcut that does not replace a standard editing or macOS system command."
        }
    }
}

struct HotkeyConfig: Codable, Equatable {
    let keyCode: Int
    let modifiers: Int

    static let `default` = HotkeyConfig(
        keyCode: kVK_ANSI_V,
        modifiers: controlKey | optionKey
    )

    // ⌥⌘V shadows Finder's "Move Item Here", so it is only kept for users who had it.
    static let legacyDefault = HotkeyConfig(
        keyCode: kVK_ANSI_V,
        modifiers: cmdKey | optionKey
    )

    var displayString: String {
        displayString(layoutLabelProvider: Self.currentKeyboardLayoutLabel)
    }

    func displayString(
        layoutLabelProvider: (Int) -> String?
    ) -> String {
        var parts: [String] = []
        if modifiers & controlKey != 0 { parts.append("⌃") }
        if modifiers & optionKey != 0 { parts.append("⌥") }
        if modifiers & shiftKey != 0 { parts.append("⇧") }
        if modifiers & cmdKey != 0 { parts.append("⌘") }
        parts.append(keyLabel(layoutLabelProvider: layoutLabelProvider))
        return parts.joined()
    }

    var validationError: HotkeyConfigValidationError? {
        guard (0...127).contains(keyCode) else {
            return .keyCodeOutOfRange
        }

        let allowedModifiers = cmdKey | optionKey | controlKey | shiftKey
        guard modifiers != 0, modifiers & ~allowedModifiers == 0 else {
            return .unsupportedModifiers
        }

        guard modifiers & (cmdKey | optionKey | controlKey) != 0 else {
            return .unsafeModifierCombination
        }
        let primaryModifiers = [cmdKey, optionKey, controlKey]
            .filter { modifiers & $0 != 0 }
        if primaryModifiers.count == 1,
           Self.unsafeSingleModifierKeyCodes.contains(keyCode) {
            return .unsafeEditingShortcut
        }
        if Self.unsafeMultiModifierShortcuts.contains(
            UnsafeShortcut(keyCode: keyCode, modifiers: modifiers)
        ) {
            return .unsafeSystemShortcut
        }

        return nil
    }

    var keyLabel: String {
        keyLabel(layoutLabelProvider: Self.currentKeyboardLayoutLabel)
    }

    func keyLabel(
        layoutLabelProvider: (Int) -> String?
    ) -> String {
        if let rawLayoutLabel = layoutLabelProvider(keyCode),
           let layoutLabel = Self.normalizedLayoutLabel(rawLayoutLabel) {
            return layoutLabel
        }

        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Escape: return "⎋"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return "Key\(keyCode)"
        }
    }

    private static func currentKeyboardLayoutLabel(for keyCode: Int) -> String? {
        KeyboardLayoutTranslator.current()?(keyCode)
    }

    private static func normalizedLayoutLabel(_ label: String) -> String? {
        guard !label.isEmpty,
              label.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && !CharacterSet.whitespacesAndNewlines.contains($0)
              }) else {
            return nil
        }
        return label.uppercased(with: .current)
    }

    static func load(from defaults: UserDefaults = .standard) -> HotkeyConfig {
        savedConfig(in: defaults) ?? .default
    }

    private static func savedConfig(in defaults: UserDefaults) -> HotkeyConfig? {
        guard let data = defaults.data(forKey: DefaultsKey.hotkeyConfig),
              let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data),
              config.validationError == nil else {
            return nil
        }
        return config
    }

    static func migrateLegacyDefaultIfNeeded(in defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: DefaultsKey.didMigrateLegacyDefault) else {
            return
        }
        if savedConfig(in: defaults) == nil,
           defaults.bool(forKey: DefaultsKey.hasCompletedWelcome) {
            legacyDefault.save(to: defaults)
        }
        defaults.set(true, forKey: DefaultsKey.didMigrateLegacyDefault)
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: DefaultsKey.hotkeyConfig)
        }
    }

    enum DefaultsKey {
        static let hotkeyConfig = "hotkeyConfig"
        static let hasCompletedWelcome = "hasCompletedWelcome"
        static let didMigrateLegacyDefault = "didMigrateLegacyHotkeyDefaultV1"
    }

    private static let unsafeSingleModifierKeyCodes: Set<Int> = Set([
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
        kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
        kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
        kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
        kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
        kVK_ANSI_Z, kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
        kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
        kVK_ANSI_9, kVK_Space, kVK_Return, kVK_Tab, kVK_Delete,
        kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow,
        kVK_DownArrow, kVK_Escape
    ])

    private struct UnsafeShortcut: Hashable {
        let keyCode: Int
        let modifiers: Int
    }

    private static let unsafeMultiModifierShortcuts: Set<UnsafeShortcut> = [
        // Standard editing commands.
        UnsafeShortcut(
            keyCode: kVK_ANSI_V,
            modifiers: cmdKey | optionKey | shiftKey
        ),

        // macOS and application-wide system commands.
        UnsafeShortcut(keyCode: kVK_Escape, modifiers: cmdKey | optionKey),
        UnsafeShortcut(keyCode: kVK_ANSI_Q, modifiers: cmdKey | controlKey),
        UnsafeShortcut(keyCode: kVK_Space, modifiers: cmdKey | controlKey),
        UnsafeShortcut(keyCode: kVK_ANSI_F, modifiers: cmdKey | controlKey),
        UnsafeShortcut(keyCode: kVK_ANSI_D, modifiers: cmdKey | optionKey),
        UnsafeShortcut(keyCode: kVK_ANSI_H, modifiers: cmdKey | optionKey),
        UnsafeShortcut(keyCode: kVK_ANSI_M, modifiers: cmdKey | optionKey),
        UnsafeShortcut(keyCode: kVK_Space, modifiers: cmdKey | optionKey),
    ]
}

enum KeyboardLayoutTranslator {
    static func current() -> ((Int) -> String?)? {
        TISCopyCurrentKeyboardLayoutInputSource().flatMap {
            labelProvider(for: $0.takeRetainedValue())
        }
    }

    static func currentASCIICapable() -> ((Int) -> String?)? {
        TISCopyCurrentASCIICapableKeyboardLayoutInputSource().flatMap {
            labelProvider(for: $0.takeRetainedValue())
        }
    }

    static func labelProvider(for inputSource: TISInputSource) -> ((Int) -> String?)? {
        guard let property = TISGetInputSourceProperty(
            inputSource,
            kTISPropertyUnicodeKeyLayoutData
        ) else {
            return nil
        }

        let layoutData = unsafeBitCast(property, to: CFData.self)
        let keyboardType = UInt32(LMGetKbdType())
        return { keyCode in
            translate(keyCode: keyCode, layoutData: layoutData, keyboardType: keyboardType)
        }
    }

    private static func translate(
        keyCode: Int,
        layoutData: CFData,
        keyboardType: UInt32
    ) -> String? {
        guard let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        let keyboardLayout = UnsafePointer<UCKeyboardLayout>(
            OpaquePointer(bytes)
        )
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var actualLength = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &actualLength,
            &characters
        )
        guard status == noErr, actualLength > 0 else {
            return nil
        }

        return String(
            utf16CodeUnits: characters,
            count: actualLength
        )
    }
}
