import AppKit
import SwiftUI

enum ClipboardPanelPresentationContext: Equatable {
    case menuBar
    case mainWindow

    var showsOpenMainWindowButton: Bool {
        self == .menuBar
    }

    var resetsSearchOnPresentation: Bool {
        self == .menuBar
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var pasteTargetController: PasteTargetController
    let presentationContext: ClipboardPanelPresentationContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var contentFilter: ClipboardContentFilter = .all
    @State private var selection = ClipboardPanelSelection()
    @State private var pendingDestructiveAction: DestructiveAction?
    @FocusState private var isSearchFocused: Bool
    @AccessibilityFocusState private var accessibilityFocusedItemID: ClipboardItem.ID?

    var body: some View {
        let visible = store.visibleItems(matching: searchText, filter: contentFilter)
        let pinned = visible.filter(\.isPinned)
        let recent = visible.filter { !$0.isPinned }

        return VStack(spacing: 0) {
            ClipboardPanelHeader(
                store: store,
                showsOpenMainWindowButton: presentationContext.showsOpenMainWindowButton,
                openMainWindow: openMainWindow
            )

            Divider()

            ClipboardPanelSearchControls(
                searchText: $searchText,
                contentFilter: $contentFilter,
                issueMessage: displayedIssue?.message,
                submit: { _ = copySelectedItem() },
                dismissIssue: dismissIssue,
                searchFocus: $isSearchFocused
            )

            ClipboardPanelHistoryList(
                visible: visible,
                pinned: pinned,
                recent: recent,
                emptyReason: emptyHistoryReason,
                selectedItemID: $selection.primaryID,
                reduceMotion: reduceMotion,
                row: row
            )

            Divider()

            ClipboardPanelFooter(
                historySummary: store.historySummaryText,
                clearableItemCount: clearableItemCount,
                keepPinnedOnClear: store.keepPinnedOnClear,
                selectedItemCount: selectedItems.count,
                selectedPinnedCount: selectedItems.filter(\.isPinned).count,
                pinSelection: { setSelectionPinned(true) },
                unpinSelection: { setSelectionPinned(false) },
                requestDeleteSelection: requestDeleteSelection,
                requestClear: { pendingDestructiveAction = .clear }
            )
        }
        .background(.regularMaterial)
        .confirmationDialog(
            destructiveConfirmationTitle,
            isPresented: Binding(
                get: { pendingDestructiveAction != nil },
                set: { if !$0 { pendingDestructiveAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(destructiveConfirmationActionTitle, role: .destructive) {
                performPendingDestructiveAction()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(destructiveConfirmationMessage)
        }
        .background(
            ClipboardPanelKeyboardBridge { action in
                handleKeyAction(action)
            }
            .frame(width: 0, height: 0)
        )
        .onAppear {
            prepareForPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .copyClipFocusSearch)) { _ in
            prepareForPresentation()
        }
        .onChange(of: visible.map(\.id)) { _, _ in
            reconcileSelection()
        }
        .onChange(of: selection.primaryID) { _, newID in
            accessibilityFocusedItemID = newID
        }
    }

    private func row(for item: ClipboardItem) -> some View {
        ClipboardItemRow(
            item: item,
            rowID: item.id,
            isCopied: store.lastCopiedID == item.id,
            isSelected: selection.selectedIDs.contains(item.id),
            thumbnailData: store.cachedThumbnailData(for: item),
            activate: {
                let modifier = currentSelectionModifier()
                select(item.id, modifier: modifier)
                guard modifier == .single else { return }
                activate(item)
            },
            copy: {
                selection = .single(item.id)
                store.copy(item)
            },
            copyWithoutFormatting: item.contentKind == .text ? {
                selection = .single(item.id)
                store.copyWithoutFormatting(item)
            } : nil,
            togglePin: {
                selection = .single(item.id)
                store.togglePin(item)
            },
            delete: {
                deleteItem(item)
            },
            ignoreApplication: ignoreApplicationAction(for: item),
            transform: item.contentKind == .text ? { transformation in
                selection = .single(item.id)
                store.copyWithTransformation(item, transformation: transformation)
            } : nil,
            dragProvider: {
                store.dragItemProvider(for: item)
            }
        )
        .accessibilityFocused($accessibilityFocusedItemID, equals: item.id)
    }

    private func ignoreApplicationAction(for item: ClipboardItem) -> (() -> Void)? {
        guard let application = item.sourceApplication,
              !store.isApplicationIgnored(application) else {
            return nil
        }

        return {
            store.addIgnoredApplication(application)
        }
    }

    private func handleKeyAction(_ action: ClipboardPanelKeyAction) -> Bool {
        switch action {
        case .moveUp:
            return moveSelection(by: -1)
        case .moveDown:
            return moveSelection(by: 1)
        case .copySelected:
            return copySelectedItem()
        case .deleteSelected:
            return deleteSelectedItem()
        case .togglePinSelected:
            return togglePinSelectedItem()
        case .focusSearch:
            focusSearch()
            return true
        case .copySelectedWithoutFormatting:
            return copySelectedWithoutFormatting()
        case let .quickSelect(number):
            return quickSelect(number)
        }
    }

    private var emptyHistoryReason: EmptyHistoryReason {
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if store.items.isEmpty {
            return isSearching ? .noMatches : .noHistory
        }

        if isSearching {
            return .noMatches
        }

        switch contentFilter {
        case .all:
            return .noHistory
        case .text:
            return .noTextClips
        case .images:
            return .noImageClips
        case .links:
            return .noLinkClips
        case .pinned:
            return .noPinnedClips
        }
    }

    private var clearableItemCount: Int {
        if store.keepPinnedOnClear {
            return store.items.filter { !$0.isPinned }.count
        }

        return store.items.count
    }

    private var destructiveConfirmationTitle: String {
        switch pendingDestructiveAction {
        case .clear, nil:
            return store.keepPinnedOnClear ? "Clear Unpinned Clips?" : "Clear All Clips?"
        case let .deleteSelection(ids):
            return "Delete \(clipCount(ids.count))?"
        }
    }

    private var destructiveConfirmationActionTitle: String {
        switch pendingDestructiveAction {
        case .clear, nil:
            return store.keepPinnedOnClear ? "Clear Unpinned" : "Clear All"
        case .deleteSelection:
            return "Delete Selection"
        }
    }

    private var destructiveConfirmationMessage: String {
        switch pendingDestructiveAction {
        case .clear, nil:
            let itemText = clipCount(clearableItemCount)
            if store.keepPinnedOnClear {
                return "This will delete \(itemText). Pinned clips will stay in your history."
            }
            return "This will permanently delete \(itemText) from your history."
        case let .deleteSelection(ids):
            return "This will permanently delete \(clipCount(ids.count)) from your history."
        }
    }

    private func clearHistory() {
        Task {
            await store.clearHistory()
            reconcileSelection()
        }
    }

    private func moveSelection(by offset: Int) -> Bool {
        let visibleItems = displayedItems()
        let nextSelection = ClipboardPanelModel.movedSelection(
            selectedID: selection.primaryID,
            by: offset,
            displayedItems: visibleItems
        )
        selection = .single(nextSelection)
        return nextSelection != nil
    }

    private func copySelectedItem() -> Bool {
        let visibleItems = displayedItems()
        guard let item = selectedItem() ?? visibleItems.first else {
            return false
        }

        selection = .single(item.id)
        activate(item)
        return true
    }

    private func copySelectedWithoutFormatting() -> Bool {
        guard let item = selectedItem(), item.contentKind == .text else {
            return false
        }
        selection = .single(item.id)
        return store.copyWithoutFormatting(item)
    }

    private func quickSelect(_ number: Int) -> Bool {
        guard let item = ClipboardPanelModel.item(
            forQuickSelectionNumber: number,
            displayedItems: displayedItems()
        ) else {
            return false
        }
        selection = .single(item.id)
        activate(item)
        return true
    }

    private func deleteSelectedItem() -> Bool {
        let selectedIDs = selection.selectedIDs
        guard !selectedIDs.isEmpty else {
            return false
        }
        if selectedIDs.count > 1 {
            pendingDestructiveAction = .deleteSelection(selectedIDs)
        } else if let item = selectedItem() {
            if item.isPinned {
                pendingDestructiveAction = .deleteSelection([item.id])
            } else {
                deleteItem(item)
            }
        }
        return true
    }

    private func deleteItem(_ item: ClipboardItem) {
        let before = displayedItems()
        let selectedID = selection.primaryID
        Task {
            await store.delete(item)
            let after = displayedItems()
            selection = .single(
                ClipboardPanelOrdering.selectionAfterDeleting(
                    deletedID: item.id,
                    selectedID: selectedID,
                    before: before,
                    after: after
                )
            )
        }
    }

    private func togglePinSelectedItem() -> Bool {
        guard selectedItem() != nil else {
            return false
        }

        let shouldPin = !selectedItems.allSatisfy(\.isPinned)
        store.setPinned(shouldPin, ids: selection.selectedIDs)
        return true
    }

    private func selectedItem() -> ClipboardItem? {
        guard let selectedItemID = selection.primaryID else {
            return nil
        }

        return displayedItems().first { $0.id == selectedItemID }
    }

    private func reconcileSelection() {
        selection = ClipboardPanelModel.reconciledSelection(
            selection,
            displayedItems: displayedItems()
        )
    }

    private func displayedItems() -> [ClipboardItem] {
        ClipboardPanelOrdering.displayedItems(
            store.visibleItems(matching: searchText, filter: contentFilter)
        )
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            isSearchFocused = true
        }
    }

    private func prepareForPresentation() {
        if presentationContext.resetsSearchOnPresentation {
            searchText = ""
            contentFilter = .all
        }
        focusSearch()
        reconcileSelection()
    }

    private func activate(_ item: ClipboardItem) {
        if store.directPasteEnabled {
            pasteTargetController.paste(item, using: store)
        } else {
            store.copy(item)
        }
    }

    private func select(
        _ id: ClipboardItem.ID,
        modifier: ClipboardPanelSelectionModifier
    ) {
        selection = ClipboardPanelModel.selection(
            afterSelecting: id,
            modifier: modifier,
            current: selection,
            displayedItems: displayedItems()
        )
    }

    private func currentSelectionModifier() -> ClipboardPanelSelectionModifier {
        let modifiers = NSApp.currentEvent?.modifierFlags
            .intersection(.deviceIndependentFlagsMask) ?? []
        if modifiers.contains(.shift) {
            return .range
        }
        if modifiers.contains(.command) {
            return .toggle
        }
        return .single
    }

    private var selectedItems: [ClipboardItem] {
        displayedItems().filter { selection.selectedIDs.contains($0.id) }
    }

    private func setSelectionPinned(_ isPinned: Bool) {
        store.setPinned(isPinned, ids: selection.selectedIDs)
        reconcileSelection()
    }

    private func requestDeleteSelection() {
        guard selection.selectedIDs.count > 1 else { return }
        pendingDestructiveAction = .deleteSelection(selection.selectedIDs)
    }

    private func performPendingDestructiveAction() {
        let action = pendingDestructiveAction
        pendingDestructiveAction = nil
        switch action {
        case .clear:
            clearHistory()
        case let .deleteSelection(ids):
            deleteSelection(ids)
        case nil:
            break
        }
    }

    private func deleteSelection(_ ids: Set<ClipboardItem.ID>) {
        let before = displayedItems()
        let selectedID = selection.primaryID
        Task {
            await store.delete(ids: ids)
            let after = displayedItems()
            let nextID = selectedID.flatMap {
                ClipboardPanelOrdering.selectionAfterDeleting(
                    deletedID: $0,
                    selectedID: $0,
                    before: before,
                    after: after
                )
            } ?? after.first?.id
            selection = .single(nextID)
        }
    }

    private func clipCount(_ count: Int) -> String {
        count == 1 ? "1 clip" : "\(count) clips"
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .copyClipFocusSearch, object: nil)
    }

    private enum DisplayedIssue {
        case paste(String)
        case storage(String)
        case pasteboardWrite(String)
        case capture(String)

        var message: String {
            switch self {
            case let .paste(message),
                 let .storage(message),
                 let .pasteboardWrite(message),
                 let .capture(message):
                message
            }
        }
    }

    private var displayedIssue: DisplayedIssue? {
        if let message = pasteTargetController.lastError {
            return .paste(message)
        }
        if let message = store.storageErrorMessage {
            return .storage(message)
        }
        if let message = store.pasteboardWriteWarning {
            return .pasteboardWrite(message)
        }
        if let message = store.captureWarning {
            return .capture(message)
        }
        return nil
    }

    private func dismissIssue() {
        switch displayedIssue {
        case .paste:
            pasteTargetController.dismissError()
        case .storage:
            store.dismissStorageError()
        case .pasteboardWrite:
            store.dismissPasteboardWriteWarning()
        case .capture:
            store.dismissCaptureWarning()
        case nil:
            break
        }
    }

    private enum DestructiveAction {
        case clear
        case deleteSelection(Set<ClipboardItem.ID>)
    }
}
