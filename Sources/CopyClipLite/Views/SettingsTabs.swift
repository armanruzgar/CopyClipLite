import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var loginItem: LoginItemController
    @State private var pendingHistoryLimit: PendingHistoryLimit?

    private var historyLimit: Binding<Int> {
        Binding(get: { store.historyLimit }, set: { requestHistoryLimit($0) })
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
    }

    private var monitoringEnabled: Binding<Bool> {
        Binding(get: { store.isMonitoringEnabled }, set: { store.setMonitoringEnabled($0) })
    }

    var body: some View {
        Form {
            Section("History") {
                Stepper(value: historyLimit, in: 10...200, step: 10) {
                    LabeledContent("Unpinned clip limit", value: "\(store.historyLimit)")
                }
                Toggle("Keep pinned items when clearing", isOn: $store.keepPinnedOnClear)
            }
            Section("Monitoring") {
                Toggle("Monitor clipboard", isOn: monitoringEnabled)
                LabeledContent("Status", value: store.monitoringStatusText)
                Menu {
                    ForEach(ClipboardPauseDuration.allCases) { duration in
                        Button(duration.title) { store.pauseMonitoring(for: duration) }
                    }
                } label: {
                    Label("Pause Monitoring", systemImage: "pause.circle")
                }
            }
            Section("Startup") {
                Toggle("Launch at Login", isOn: launchAtLogin)
                LabeledContent("Status", value: loginItem.statusText)
                if loginItem.needsApproval {
                    Button("Open Login Items Settings") { loginItem.openLoginItemsSettings() }
                }
                if let errorMessage = loginItem.errorMessage {
                    SettingsErrorText(errorMessage)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reduce Unpinned Clip Limit?",
            isPresented: Binding(
                get: { pendingHistoryLimit != nil },
                set: { if !$0 { pendingHistoryLimit = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Apply New Limit", role: .destructive) {
                guard let pendingHistoryLimit else { return }
                store.setHistoryLimit(pendingHistoryLimit.limit)
                self.pendingHistoryLimit = nil
            }
            Button("Cancel", role: .cancel) { pendingHistoryLimit = nil }
        } message: {
            if let pendingHistoryLimit {
                Text(
                    "This will permanently delete \(clipCountText(pendingHistoryLimit.deletedCount)) beyond the new \(pendingHistoryLimit.limit)-clip limit."
                )
            }
        }
    }

    private func requestHistoryLimit(_ limit: Int) {
        let deletedCount = store.prospectiveDeletionCount(historyLimit: limit)
        guard deletedCount > 0 else {
            store.setHistoryLimit(limit)
            return
        }
        pendingHistoryLimit = PendingHistoryLimit(limit: limit, deletedCount: deletedCount)
    }
}

struct PrivacySettingsView: View {
    @ObservedObject var store: ClipboardStore
    let addIgnoredApplication: () -> Void
    @State private var pendingRetentionPolicy: PendingRetentionPolicy?

    private var retentionPolicy: Binding<ClipboardRetentionPolicy> {
        Binding(get: { store.retentionPolicy }, set: { requestRetentionPolicy($0) })
    }

    var body: some View {
        Form {
            Section("Retention") {
                Picker("Auto-clear unpinned clips", selection: retentionPolicy) {
                    ForEach(ClipboardRetentionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("Pinned clips", value: "Never auto-clear")
                Toggle("Clear unpinned history when quitting", isOn: $store.clearUnpinnedOnQuit)
            }
            Section("Source Exclusions") {
                Text("macOS does not expose guaranteed clipboard ownership. CopyClip checks the active app at the instant a change is detected and also skips concealed or transient clipboard data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Common credential managers are excluded on first run. You can remove or add apps here at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.ignoredApplications.isEmpty {
                    Text("No excluded apps").foregroundStyle(.secondary)
                } else {
                    ForEach(store.ignoredApplications) { application in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(application.name)
                                Text(application.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.removeIgnoredApplication(application)
                            } label: {
                                Label("Remove \(application.name)", systemImage: "minus.circle")
                                    .labelStyle(.iconOnly)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button(action: addIgnoredApplication) {
                    Label("Exclude an App", systemImage: "plus")
                }
            }
            Section("At Rest") {
                Text("History is stored locally with owner-only file permissions. It is not separately encrypted, so enable FileVault when clipboard confidentiality matters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Change Auto-Clear Policy?",
            isPresented: Binding(
                get: { pendingRetentionPolicy != nil },
                set: { if !$0 { pendingRetentionPolicy = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Apply Auto-Clear Policy", role: .destructive) {
                guard let pendingRetentionPolicy else { return }
                store.setRetentionPolicy(pendingRetentionPolicy.policy)
                self.pendingRetentionPolicy = nil
            }
            Button("Cancel", role: .cancel) { pendingRetentionPolicy = nil }
        } message: {
            if let pendingRetentionPolicy {
                Text(
                    "This will permanently delete \(clipCountText(pendingRetentionPolicy.deletedCount)) under “\(pendingRetentionPolicy.policy.title)”."
                )
            }
        }
    }

    private func requestRetentionPolicy(_ policy: ClipboardRetentionPolicy) {
        let deletedCount = store.prospectiveDeletionCount(retentionPolicy: policy)
        guard deletedCount > 0 else {
            store.setRetentionPolicy(policy)
            return
        }
        pendingRetentionPolicy = PendingRetentionPolicy(
            policy: policy,
            deletedCount: deletedCount
        )
    }
}

private struct PendingHistoryLimit {
    let limit: Int
    let deletedCount: Int
}

private struct PendingRetentionPolicy {
    let policy: ClipboardRetentionPolicy
    let deletedCount: Int
}

private func clipCountText(_ count: Int) -> String {
    count == 1 ? "1 clip" : "\(count) clips"
}

struct ShortcutSettingsView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var hotkeyController: GlobalHotkeyController
    @ObservedObject var pasteTargetController: PasteTargetController

    var body: some View {
        Form {
            Section("Global Hotkey") {
                LabeledContent("Open clipboard search") {
                    HotkeyRecorder(config: hotkeyController.config) { newConfig in
                        hotkeyController.updateConfig(newConfig)
                    } onRecordingChanged: { isRecording in
                        hotkeyController.setRecording(isRecording)
                    }
                    .frame(width: 180, height: 28)
                }
                if let errorMessage = hotkeyController.errorMessage {
                    SettingsErrorText(errorMessage)
                }
                Button("Reset to Default (\(HotkeyConfig.default.displayString))") {
                    hotkeyController.updateConfig(.default)
                }
            }
            Section("Direct Paste") {
                Toggle("Copy and paste into the previous app", isOn: $store.directPasteEnabled)
                Text("Direct Paste returns focus to the last app you used before sending ⌘V.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.directPasteEnabled {
                    LabeledContent(
                        "Paste target",
                        value: pasteTargetController.targetApplicationName ?? "Open a destination app"
                    )
                    LabeledContent(
                        "Accessibility permission",
                        value: pasteTargetController.isAccessibilityGranted ? "Granted" : "Required"
                    )
                    if !pasteTargetController.isAccessibilityGranted {
                        HStack {
                            Button("Request Permission") { pasteTargetController.requestPermission() }
                            Button("Open System Settings") { pasteTargetController.openAccessibilitySettings() }
                        }
                    }
                }
                if let errorMessage = pasteTargetController.lastError {
                    SettingsErrorText(errorMessage)
                }
            }
            Section("List Keyboard Controls") {
                LabeledContent("Move selection", value: "↑ / ↓")
                LabeledContent("Use selected clip", value: "Return")
                LabeledContent("Use clip by position", value: "⌘1 – ⌘9")
                LabeledContent("Copy as plain text", value: "⇧⌘V")
                LabeledContent("Pin or unpin selection", value: "⌘P")
                LabeledContent("Delete selection", value: "⌘⌫")
                LabeledContent("Focus search", value: "⌘F")
                Text("Shift-click selects a range. Command-click adds or removes one clip from the selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SettingsErrorText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}
