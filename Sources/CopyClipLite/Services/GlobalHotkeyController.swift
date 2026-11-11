import AppKit
import Carbon
import Foundation

enum GlobalHotkeyRegistrationError: LocalizedError, Equatable {
    case handler(OSStatus)
    case registration(OSStatus, shortcut: String)

    var errorDescription: String? {
        switch self {
        case let .handler(status):
            return "Hotkey handler failed (\(status))."
        case let .registration(status, shortcut):
            if status == eventHotKeyExistsErr {
                return "\(shortcut) is already in use."
            }
            return "\(shortcut) could not be registered (\(status))."
        }
    }
}

@MainActor
protocol GlobalHotkeyRegistering: AnyObject {
    var isRegistered: Bool { get }
    func installHandler(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, GlobalHotkeyRegistrationError>
    func replace(with config: HotkeyConfig) -> Result<Void, GlobalHotkeyRegistrationError>
    func suspend()
    func resume() -> Result<Void, GlobalHotkeyRegistrationError>
}

@MainActor
final class CarbonGlobalHotkeyRegistrar: GlobalHotkeyRegistering {
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    private let handlerBox = HotkeyHandlerBox()
    private var currentConfig: HotkeyConfig?
    private var nextHotKeyID: UInt32 = 1

    var isRegistered: Bool {
        hotKeyRef != nil
    }

    func installHandler(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, GlobalHotkeyRegistrationError> {
        if eventHandlerRef != nil {
            handlerBox.action = action
            return .success(())
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        handlerBox.action = action
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleHotKeyEvent,
            1,
            &eventType,
            Unmanaged.passUnretained(handlerBox).toOpaque(),
            &installedHandler
        )

        guard status == noErr else {
            handlerBox.action = nil
            return .failure(.handler(status))
        }

        eventHandlerRef = installedHandler
        return .success(())
    }

    func replace(with config: HotkeyConfig) -> Result<Void, GlobalHotkeyRegistrationError> {
        var newHotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: nextHotKeyID
        )
        let status = RegisterEventHotKey(
            UInt32(config.keyCode),
            UInt32(config.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &newHotKeyRef
        )

        guard status == noErr, let newHotKeyRef else {
            return .failure(.registration(status, shortcut: config.displayString))
        }

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = newHotKeyRef
        currentConfig = config
        nextHotKeyID &+= 1
        return .success(())
    }

    func suspend() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    func resume() -> Result<Void, GlobalHotkeyRegistrationError> {
        guard hotKeyRef == nil, let currentConfig else {
            return .success(())
        }
        return replace(with: currentConfig)
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        handlerBox.action = nil
    }

    private static let handleHotKeyEvent: EventHandlerUPP = { _, _, userData in
        guard let userData else {
            return noErr
        }
        let box = Unmanaged<HotkeyHandlerBox>
            .fromOpaque(userData)
            .takeUnretainedValue()
        DispatchQueue.main.async {
            box.action?()
        }
        return noErr
    }

    private final class HotkeyHandlerBox: @unchecked Sendable {
        nonisolated(unsafe) var action: (@MainActor @Sendable () -> Void)?
    }

    private static let hotKeySignature: OSType = {
        let bytes = Array("CCLT".utf8)
        return OSType(bytes[0]) << 24
            | OSType(bytes[1]) << 16
            | OSType(bytes[2]) << 8
            | OSType(bytes[3])
    }()
}

@MainActor
final class GlobalHotkeyController: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var config: HotkeyConfig

    var action: (() -> Void)?

    private let registrar: any GlobalHotkeyRegistering
    private let defaults: UserDefaults

    var statusText: String {
        if isRegistered {
            return config.displayString
        }
        return errorMessage ?? "Unavailable"
    }

    convenience init(config: HotkeyConfig = HotkeyConfig.load()) {
        self.init(config: config, registrar: CarbonGlobalHotkeyRegistrar())
    }

    init(
        config: HotkeyConfig,
        registrar: any GlobalHotkeyRegistering,
        defaults: UserDefaults = .standard
    ) {
        self.config = config.validationError == nil ? config : .default
        self.registrar = registrar
        self.defaults = defaults

        switch registrar.installHandler(action: { [weak self] in
            self?.performAction()
        }) {
        case .success:
            applyRegistration(of: self.config, persist: false)
        case let .failure(error):
            isRegistered = false
            errorMessage = error.localizedDescription
        }
    }

    func updateConfig(_ newConfig: HotkeyConfig) {
        guard let validationError = newConfig.validationError else {
            if newConfig == config, registrar.isRegistered {
                newConfig.save(to: defaults)
                isRegistered = true
                errorMessage = nil
                return
            }
            applyRegistration(of: newConfig, persist: true)
            return
        }
        errorMessage = validationError.localizedDescription
    }

    func setRecording(_ isRecording: Bool) {
        if isRecording {
            registrar.suspend()
            isRegistered = false
            return
        }

        switch registrar.resume() {
        case .success:
            isRegistered = registrar.isRegistered
            errorMessage = nil
        case let .failure(error):
            isRegistered = false
            errorMessage = error.localizedDescription
        }
    }

    private func applyRegistration(of newConfig: HotkeyConfig, persist: Bool) {
        switch registrar.replace(with: newConfig) {
        case .success:
            config = newConfig
            if persist {
                newConfig.save(to: defaults)
            }
            isRegistered = true
            errorMessage = nil
        case let .failure(error):
            isRegistered = registrar.isRegistered
            errorMessage = error.localizedDescription
        }
    }

    private func performAction() {
        action?()
    }
}
