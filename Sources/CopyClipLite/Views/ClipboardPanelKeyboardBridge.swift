import AppKit
import SwiftUI

enum ClipboardPanelKeyAction: Equatable {
    case moveUp
    case moveDown
    case copySelected
    case deleteSelected
    case togglePinSelected
    case focusSearch
    case copySelectedWithoutFormatting
    case quickSelect(Int)
}

struct ClipboardPanelKeyInput {
    let keyCode: UInt16
    let charactersIgnoringModifiers: String?
    let modifierFlags: NSEvent.ModifierFlags
    let focusContext: ClipboardPanelKeyFocusContext
}

enum ClipboardPanelKeyFocusContext: Equatable {
    case list
    case textEditor(hasText: Bool)
    case control
}

enum ClipboardPanelKeyRouting {
    @MainActor
    static func action(
        for event: NSEvent,
        firstResponder: NSResponder?
    ) -> ClipboardPanelKeyAction? {
        action(
            for: ClipboardPanelKeyInput(
                keyCode: event.keyCode,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags,
                focusContext: focusContext(for: firstResponder)
            )
        )
    }

    @MainActor
    private static func focusContext(for firstResponder: NSResponder?) -> ClipboardPanelKeyFocusContext {
        guard let firstResponder else { return .list }
        guard let textView = firstResponder as? NSTextView else { return .control }
        return .textEditor(hasText: !textView.string.isEmpty)
    }

    static func action(for input: ClipboardPanelKeyInput) -> ClipboardPanelKeyAction? {
        let modifiers = input.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let normalizedModifiers = modifiers.subtracting([.capsLock, .numericPad, .function])
        let commandOnly = normalizedModifiers == .command
        let noModifiers = normalizedModifiers.isEmpty

        if commandOnly, input.charactersIgnoringModifiers?.lowercased() == "f" {
            return .focusSearch
        }

        if commandOnly,
           let characters = input.charactersIgnoringModifiers,
           let number = Int(characters),
           (1...9).contains(number) {
            return .quickSelect(number)
        }

        if commandOnly, input.charactersIgnoringModifiers?.lowercased() == "p" {
            return .togglePinSelected
        }

        if commandOnly, input.keyCode == 51 || input.keyCode == 117 {
            // Leave ⌘⌫ / ⌘⌦ to the text field so they keep deleting to the line boundary.
            if input.focusContext == .textEditor(hasText: true) {
                return nil
            }
            return .deleteSelected
        }

        if normalizedModifiers == [.command, .shift],
           input.charactersIgnoringModifiers?.lowercased() == "v" {
            return .copySelectedWithoutFormatting
        }

        guard noModifiers else {
            return nil
        }

        guard input.focusContext != .control else {
            return nil
        }

        switch input.keyCode {
        case 125:
            return .moveDown
        case 126:
            return .moveUp
        case 36, 76:
            return .copySelected
        default:
            return nil
        }
    }

    static func handle(
        _ input: ClipboardPanelKeyInput,
        using handler: (ClipboardPanelKeyAction) -> Bool
    ) -> Bool {
        guard let action = action(for: input) else {
            return false
        }
        return handler(action)
    }

    @MainActor
    static func handle(
        _ event: NSEvent,
        firstResponder: NSResponder?,
        using handler: (ClipboardPanelKeyAction) -> Bool
    ) -> Bool {
        guard let action = action(for: event, firstResponder: firstResponder) else {
            return false
        }
        return handler(action)
    }
}

struct ClipboardPanelKeyboardBridge: NSViewRepresentable {
    let handle: (ClipboardPanelKeyAction) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(handle: handle)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var handle: (ClipboardPanelKeyAction) -> Bool
        private var monitor: Any?

        init(handle: @escaping (ClipboardPanelKeyAction) -> Bool) {
            self.handle = handle
        }

        func installMonitor() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.eventBelongsToViewWindow(event) else {
                    return event
                }

                return self.handle(event) ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            ClipboardPanelKeyRouting.handle(
                event,
                firstResponder: view?.window?.firstResponder,
                using: handle
            )
        }

        private func eventBelongsToViewWindow(_ event: NSEvent) -> Bool {
            guard let window = view?.window else {
                return false
            }

            return event.window === window
        }
    }
}
