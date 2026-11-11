import AppKit
import Carbon
import CoreGraphics

enum PasteSimulator {
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        )
    }

    static func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )
    }

    @discardableResult
    static func simulatePaste(targetProcessIdentifier: pid_t) -> Bool {
        guard targetProcessIdentifier > 0 else {
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = pasteKeyCode()

        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        )
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        )
        keyUp?.flags = .maskCommand

        guard let keyDown, let keyUp else {
            return false
        }

        keyDown.postToPid(targetProcessIdentifier)
        keyUp.postToPid(targetProcessIdentifier)
        return true
    }

    static func pasteKeyCode() -> CGKeyCode {
        pasteKeyCode(
            layoutLabelProviders: [
                KeyboardLayoutTranslator.current(),
                KeyboardLayoutTranslator.currentASCIICapable(),
            ].compactMap { $0 }
        )
    }

    static func pasteKeyCode(
        layoutLabelProviders: [(Int) -> String?]
    ) -> CGKeyCode {
        for provider in layoutLabelProviders {
            if let keyCode = (0...127).first(where: { provider($0) == "v" }) {
                return CGKeyCode(keyCode)
            }
        }
        return CGKeyCode(kVK_ANSI_V)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
