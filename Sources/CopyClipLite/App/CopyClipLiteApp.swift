import AppKit
import SwiftUI

struct CopyClipAppLaunchPolicy {
    let hasCompletedWelcome: Bool

    var suppressesInitialMainWindow: Bool {
        hasCompletedWelcome
    }

    var activatesApplicationAfterLaunch: Bool {
        !hasCompletedWelcome
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: ClipboardStore?
    private let hasCompletedWelcome: @MainActor () -> Bool
    private let applyAccessoryActivationPolicy: @MainActor () -> Void
    private let activateApplication: @MainActor () -> Void
    private let cleanupWithoutStore: @MainActor () -> Void
    private var shouldSuppressInitialMainWindow: Bool
    private(set) var resignActiveFlush: Task<Bool, Never>?

    override convenience init() {
        LegacyDefaultsMigrator.migrateIfNeeded()
        self.init(
            store: CopyClipAppRuntime.store,
            hasCompletedWelcome: {
                UserDefaults.standard.bool(forKey: "hasCompletedWelcome")
            },
            applyAccessoryActivationPolicy: {
                NSApp.setActivationPolicy(.accessory)
            },
            activateApplication: {
                NSApp.activate(ignoringOtherApps: true)
            },
            cleanupWithoutStore: {
                ClipboardStore.clearUnpinnedHistoryOnQuitIfNeeded()
            }
        )
    }

    init(
        store: ClipboardStore? = nil,
        hasCompletedWelcome: @escaping @MainActor () -> Bool,
        applyAccessoryActivationPolicy: @escaping @MainActor () -> Void,
        activateApplication: @escaping @MainActor () -> Void,
        cleanupWithoutStore: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.hasCompletedWelcome = hasCompletedWelcome
        self.applyAccessoryActivationPolicy = applyAccessoryActivationPolicy
        self.activateApplication = activateApplication
        self.cleanupWithoutStore = cleanupWithoutStore
        self.shouldSuppressInitialMainWindow = CopyClipAppLaunchPolicy(
            hasCompletedWelcome: hasCompletedWelcome()
        ).suppressesInitialMainWindow
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        LegacyDefaultsMigrator.migrateIfNeeded()
        shouldSuppressInitialMainWindow = CopyClipAppLaunchPolicy(
            hasCompletedWelcome: hasCompletedWelcome()
        ).suppressesInitialMainWindow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAccessoryActivationPolicy()

        let launchPolicy = CopyClipAppLaunchPolicy(
            hasCompletedWelcome: hasCompletedWelcome()
        )
        if launchPolicy.activatesApplicationAfterLaunch {
            activateApplication()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let store {
            store.clearUnpinnedHistoryOnQuitIfNeeded()
        } else {
            cleanupWithoutStore()
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        guard let store else { return }
        resignActiveFlush = Task { await store.flushPendingPersist() }
    }

    func consumeInitialWindowSuppression() -> Bool {
        defer { shouldSuppressInitialMainWindow = false }
        return shouldSuppressInitialMainWindow
    }
}

@main
struct CopyClipLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: ClipboardStore
    @StateObject private var loginItemController: LoginItemController
    @StateObject private var hotkeyController: GlobalHotkeyController
    @StateObject private var pasteTargetController: PasteTargetController

    init() {
        LegacyDefaultsMigrator.migrateIfNeeded()
        _store = StateObject(wrappedValue: CopyClipAppRuntime.store)
        _loginItemController = StateObject(wrappedValue: LoginItemController())
        _hotkeyController = StateObject(wrappedValue: GlobalHotkeyController())
        _pasteTargetController = StateObject(wrappedValue: PasteTargetController())
    }

    var body: some Scene {
        Window("CopyClip Lite", id: "main") {
            RootWindowView(
                store: store,
                pasteTargetController: pasteTargetController,
                hotkeyController: hotkeyController
            )
                .frame(minWidth: 390, idealWidth: 420, minHeight: 560, idealHeight: 620)
                .background(
                    InitialWindowSuppressor {
                        appDelegate.consumeInitialWindowSuppression()
                    }
                    .frame(width: 0, height: 0)
                )
        }
        .defaultSize(width: 420, height: 620)

        MenuBarExtra {
            ClipboardPanelView(
                store: store,
                pasteTargetController: pasteTargetController,
                presentationContext: .menuBar
            )
                .frame(width: 380, height: 520)
        } label: {
            Label("CopyClip Lite", systemImage: "clipboard")
                .background(
                    AppRuntimeInstaller(
                        hotkeyController: hotkeyController,
                        pasteTargetController: pasteTargetController
                    )
                    .frame(width: 0, height: 0)
                )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                store: store,
                loginItem: loginItemController,
                hotkeyController: hotkeyController,
                pasteTargetController: pasteTargetController
            )
        }
    }
}

@MainActor
private enum CopyClipAppRuntime {
    static let store: ClipboardStore = {
        LegacyDefaultsMigrator.migrateIfNeeded()
        // The staging directory is required so that only the app itself, never a
        // test, cleans up the shared drag folder in $TMPDIR.
        return ClipboardStore(
            dragStagingDirectory: ClipboardDragProviderFactory.defaultStagingDirectory
        )
    }()
}

private struct InitialWindowSuppressor: NSViewRepresentable {
    let shouldSuppress: () -> Bool

    func makeNSView(context: Context) -> NSView {
        SuppressionView(shouldSuppress: shouldSuppress)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SuppressionView: NSView {
        let shouldSuppress: () -> Bool

        init(shouldSuppress: @escaping () -> Bool) {
            self.shouldSuppress = shouldSuppress
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, shouldSuppress() else { return }
            window?.orderOut(nil)
        }
    }
}

private struct AppRuntimeInstaller: View {
    @ObservedObject var hotkeyController: GlobalHotkeyController
    @ObservedObject var pasteTargetController: PasteTargetController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasCompletedWelcome") private var hasCompletedWelcome = false

    var body: some View {
        Color.clear
            .onAppear {
                hotkeyController.action = {
                    pasteTargetController.captureCurrentTarget()
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .copyClipFocusSearch, object: nil)
                }

                if !hasCompletedWelcome {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            }
    }
}

private enum LegacyDefaultsMigrator {
    private static let legacyBundleIdentifier = "com.local.CopyClipLite"
    private static let migrationKey = "didMigrateLegacyDefaultsV1"
    private static let keys = [
        "hasCompletedWelcome",
        "historyLimit",
        "retentionPolicy",
        "keepPinnedOnClear",
        "clearUnpinnedOnQuit",
        "monitoringEnabled",
        "monitoringPausedUntil",
        "ignoredApplications",
        "directPasteEnabled",
        "hotkeyConfig",
    ]

    static func migrateIfNeeded() {
        migrateLegacyDomainIfNeeded()
        HotkeyConfig.migrateLegacyDefaultIfNeeded()
    }

    private static func migrateLegacyDomainIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey),
              Bundle.main.bundleIdentifier != legacyBundleIdentifier,
              let legacyDomain = defaults.persistentDomain(forName: legacyBundleIdentifier) else {
            return
        }

        for key in keys where defaults.object(forKey: key) == nil {
            defaults.set(legacyDomain[key], forKey: key)
        }
        defaults.set(true, forKey: migrationKey)
    }
}
