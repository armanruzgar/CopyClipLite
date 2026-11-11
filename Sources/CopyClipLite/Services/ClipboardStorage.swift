import Darwin
import Foundation

enum ClipboardStorageError: LocalizedError, Equatable {
    case unreadableHistory
    case invalidHistory(backupFileName: String?)
    case persistenceFailed
    case importTooLarge
    case tooManyImportedItems
    case duplicateImportedItem
    case invalidImportedItem(String)
    case importPlanExpired
    case missingImageData
    case incompatibleExport(String)
    case unsupportedTransferVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableHistory:
            return "Clipboard history could not be read. Your existing file was left untouched."
        case let .invalidHistory(backupFileName):
            if let backupFileName {
                return "Clipboard history was damaged and moved to \(backupFileName)."
            }
            return "Clipboard history was damaged and could not be recovered."
        case .persistenceFailed:
            return "Clipboard history could not be saved. Check the Data section in Settings."
        case .importTooLarge:
            return "The history file is too large to import safely."
        case .tooManyImportedItems:
            return "The history file contains too many clips."
        case .duplicateImportedItem:
            return "The history file contains duplicate clip identifiers."
        case let .invalidImportedItem(reason):
            return "The history file contains an invalid clip: \(reason)"
        case .importPlanExpired:
            return "Clipboard history or import settings changed. Review the import again before applying it."
        case .missingImageData:
            return "An image clip is missing its image data."
        case let .incompatibleExport(reason):
            return "Clipboard history cannot be exported: \(reason)"
        case let .unsupportedTransferVersion(version):
            return "This history uses unsupported transfer format version \(version)."
        }
    }
}

struct ClipboardThumbnailResult: Sendable {
    let data: Data
    let fileName: String
}

enum ClipboardStorageFaultPoint: Equatable {
    /// Immediately before writing a full-image or thumbnail sidecar.
    case imageWrite
    /// Immediately after a sidecar has been atomically written.
    case imageWriteCompleted
    /// Immediately before staging the next manifest.
    case manifestWrite
    /// Immediately before writing an RTF or HTML sidecar.
    case richTextWrite
    /// Immediately after a rich-text sidecar has been atomically written.
    case richTextWriteCompleted
    /// After the complete manifest is staged, immediately before its atomic commit.
    case manifestWriteCompleted
}

struct ClipboardStorage: @unchecked Sendable {
    static let maximumImportBytes = 100 * 1024 * 1024
    static let maximumImportedItems = 1_000
    static let maximumImportedTextCharacters = 20_000
    static let maximumImportedImageBytes = 10 * 1024 * 1024
    static let maximumImportedRichTextBytes = 10 * 1024 * 1024
    private static let maximumRetainedPreImportBackups = 5
    // Each recovery folder can hold a full copy of the image and rich-text sidecars.
    private static let maximumRetainedRecoveryFolders = 2

    let fileURL: URL
    let imageDirectoryURL: URL
    let richTextDirectoryURL: URL

    private let fileManager: FileManager
    private let faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)?
    private let imageSidecars: ClipboardImageSidecarStore
    private let richTextSidecars: ClipboardRichTextSidecarStore
    private let lock = NSRecursiveLock()
    private let state = ClipboardStorageState()

    var imageCleanupPending: Bool { state.imageCleanupPending }

    init(
        fileManager: FileManager = .default,
        appDirectory: URL? = nil,
        faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)? = nil
    ) {
        let appDirectory = appDirectory ?? Self.defaultAppDirectory(fileManager: fileManager)
        let imageDirectoryURL = appDirectory.appendingPathComponent("Images", isDirectory: true)
        let richTextDirectoryURL = appDirectory.appendingPathComponent("RichText", isDirectory: true)
        self.fileManager = fileManager
        self.faultInjector = faultInjector
        self.imageDirectoryURL = imageDirectoryURL
        self.richTextDirectoryURL = richTextDirectoryURL
        self.imageSidecars = ClipboardImageSidecarStore(
            directoryURL: imageDirectoryURL,
            fileManager: fileManager,
            faultInjector: faultInjector
        )
        self.richTextSidecars = ClipboardRichTextSidecarStore(
            directoryURL: richTextDirectoryURL,
            fileManager: fileManager,
            faultInjector: faultInjector
        )

        try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDirectory.path)
        for directoryURL in [imageDirectoryURL, richTextDirectoryURL] {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        }

        fileURL = appDirectory.appendingPathComponent("clipboard-history.json")
    }

    func load() -> [ClipboardItem] {
        (try? loadResult().get()) ?? []
    }

    func loadResult() -> Result<[ClipboardItem], ClipboardStorageError> {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            state.allowWrites()
            removeUnreferencedSidecars(keeping: [], richTextFileNames: [:])
            return .success([])
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            state.protectWrites()
            return .failure(.unreadableHistory)
        }

        let richTextResolver = richTextSidecars.makeResolver()
        let decoder = JSONDecoder()
        decoder.userInfo[.clipboardRichTextResolver] = richTextResolver
        var items: [ClipboardItem]
        do {
            items = try decoder.decode([ClipboardItem].self, from: data)
            guard Self.hasUniqueIdentifiers(items) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Clipboard history contains duplicate identifiers."
                    )
                )
            }
        } catch {
            let backupURL = backupExistingStore(reason: "invalid")
            if backupURL == nil {
                state.protectWrites()
            } else {
                state.allowWrites()
            }
            return .failure(.invalidHistory(backupFileName: backupURL?.lastPathComponent))
        }

        var newlyCreatedFiles = Set<URL>()
        do {
            let wasExternalized = try imageSidecars.externalizeImages(
                in: &items,
                newlyCreatedFiles: &newlyCreatedFiles
            )
            let wasHydrated = imageSidecars.hydrateMetadata(in: &items)
            richTextSidecars.remember(richTextResolver)
            let richTextFileNames = try richTextSidecars.externalize(
                items,
                newlyCreatedFiles: &newlyCreatedFiles
            )
            // Differs for legacy inline rich text and for references to missing files.
            let richTextMoved = richTextFileNames != richTextResolver.referencedFileNames
            if wasExternalized || wasHydrated || richTextMoved || Self.requiresNormalization(data) {
                try writeHistory(items, richTextFileNames: richTextFileNames)
            }
            // Retry previous cleanup failures even when the manifest needs no migration.
            removeUnreferencedSidecars(keeping: items, richTextFileNames: richTextFileNames)
            state.allowWrites()
            return .success(items)
        } catch {
            imageSidecars.removeFiles(newlyCreatedFiles)
            state.protectWrites()
            return .failure(.persistenceFailed)
        }
    }

    func save(_ items: [ClipboardItem]) {
        _ = try? saveValidated(items)
    }

    @discardableResult
    func saveValidated(_ items: [ClipboardItem]) throws -> [ClipboardItem] {
        lock.lock()
        defer { lock.unlock() }

        guard state.writesAreAllowed,
              Self.hasUniqueIdentifiers(items) else {
            throw ClipboardStorageError.persistenceFailed
        }

        var persistedItems = items
        var newlyCreatedFiles = Set<URL>()
        let richTextFileNames: [UUID: ClipboardRichTextFileNames]
        do {
            try imageSidecars.externalizeImages(
                in: &persistedItems,
                newlyCreatedFiles: &newlyCreatedFiles
            )
            richTextFileNames = try richTextSidecars.externalize(
                persistedItems,
                newlyCreatedFiles: &newlyCreatedFiles
            )
            try writeHistory(persistedItems, richTextFileNames: richTextFileNames)
        } catch {
            imageSidecars.removeFiles(newlyCreatedFiles)
            throw ClipboardStorageError.persistenceFailed
        }

        removeUnreferencedSidecars(keeping: persistedItems, richTextFileNames: richTextFileNames)
        return persistedItems
    }

    private func removeUnreferencedSidecars(
        keeping items: [ClipboardItem],
        richTextFileNames: [UUID: ClipboardRichTextFileNames]
    ) {
        var failed = false
        do {
            try imageSidecars.removeUnreferencedFiles(keeping: items)
        } catch {
            failed = true
        }
        do {
            try richTextSidecars.removeUnreferencedFiles(keeping: richTextFileNames)
        } catch {
            failed = true
        }
        // The manifest is already committed. Report cleanup separately so callers
        // never roll back a successful import or resurrect logically deleted rows.
        state.setImageCleanupPending(failed)
    }

    func imageData(for item: ClipboardItem) -> Data? {
        imageSidecars.imageData(for: item)
    }

    func thumbnailData(for item: ClipboardItem) -> Data? {
        imageSidecars.thumbnailData(for: item)
    }

    func thumbnailDataRepairingIfNeeded(for item: ClipboardItem) -> ClipboardThumbnailResult? {
        lock.lock()
        defer { lock.unlock() }

        return imageSidecars.thumbnailDataRepairingIfNeeded(for: item)
    }

    func export(_ items: [ClipboardItem], to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        guard items.count <= Self.maximumImportedItems else {
            throw ClipboardStorageError.incompatibleExport(
                ClipboardTransferCodec.itemLimitExceededReason(itemCount: items.count)
            )
        }
        let brokenItems = items.filter(imageSidecars.isMissingImageData)
        guard brokenItems.isEmpty else {
            throw ClipboardStorageError.incompatibleExport(
                Self.missingImageDataReason(for: brokenItems)
            )
        }

        var portableItems: [ClipboardItem] = []
        portableItems.reserveCapacity(items.count)
        var estimatedByteCount = 0
        for item in items {
            let portable: ClipboardItem
            do {
                portable = try imageSidecars.portableItem(item)
            } catch ClipboardStorageError.missingImageData {
                throw ClipboardStorageError.incompatibleExport(
                    Self.missingImageDataReason(for: [item])
                )
            }
            estimatedByteCount += Self.minimumEncodedByteCount(of: portable)
            guard estimatedByteCount <= Self.maximumImportBytes else {
                throw ClipboardStorageError.incompatibleExport(
                    Self.exportTooLargeReason(minimumByteCount: estimatedByteCount)
                )
            }
            portableItems.append(portable)
        }
        let data = try ClipboardTransferCodec.encode(portableItems)
        try data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A lower bound on the item's size in the exported JSON: binary fields are written
    /// as base64, which is 4/3 of their raw size.
    private static func minimumEncodedByteCount(of item: ClipboardItem) -> Int {
        let imageByteCount: Int = item.image?.data?.count ?? 0
        let thumbnailByteCount: Int = item.image?.thumbnailData?.count ?? 0
        let rtfByteCount: Int = item.rtfData?.count ?? 0
        let htmlByteCount: Int = item.htmlData?.count ?? 0
        let binaryByteCount: Int = imageByteCount + thumbnailByteCount + rtfByteCount + htmlByteCount
        let base64ByteCount: Int = (binaryByteCount + 2) / 3 * 4
        return base64ByteCount + item.text.utf8.count
    }

    private static func exportTooLargeReason(minimumByteCount: Int) -> String {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(minimumByteCount),
            countStyle: .file
        )
        let limit = ByteCountFormatter.string(
            fromByteCount: Int64(maximumImportBytes),
            countStyle: .file
        )
        return "the history is at least \(size), more than the \(limit) export limit. "
            + "Delete or unpin large image clips, then export again."
    }

    private static func missingImageDataReason(for items: [ClipboardItem]) -> String {
        let listedLimit = 3
        var descriptions = items.prefix(listedLimit).map(brokenImageDescription)
        if items.count > listedLimit {
            descriptions.append("and \(items.count - listedLimit) more")
        }
        let subject = items.count == 1
            ? "1 image clip is missing its image data"
            : "\(items.count) image clips are missing their image data"
        let object = items.count == 1 ? "it" : "them"
        return "\(subject): \(descriptions.joined(separator: "; ")). "
            + "Delete \(object) from the history, then export again."
    }

    private static func brokenImageDescription(_ item: ClipboardItem) -> String {
        var details: [String] = []
        if let image = item.image, image.width > 0, image.height > 0 {
            details.append(image.dimensionsText)
        }
        details.append(
            "last copied \(item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))"
        )
        let caption = item.text.copyClipPreview(limit: 40)
        let title = caption.isEmpty ? "Image" : "Image “\(caption)”"
        return "\(title) (\(details.joined(separator: ", ")))"
    }

    // Deliberately unlocked. This reads a caller-supplied file outside the store and
    // decodes it; it never touches the history manifest or the image sidecars. Taking
    // the store lock here would make an import wait on an in-flight save, which
    // deadlocks the pending-persist-during-import path.
    func importItems(from url: URL) throws -> [ClipboardItem] {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile == true else {
            throw ClipboardStorageError.invalidImportedItem("the selected item is not a regular file")
        }
        guard (resourceValues.fileSize ?? 0) <= Self.maximumImportBytes else {
            throw ClipboardStorageError.importTooLarge
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= Self.maximumImportBytes else {
            throw ClipboardStorageError.importTooLarge
        }

        return try importItems(data: data)
    }

    func importItems(data: Data) throws -> [ClipboardItem] {
        try ClipboardTransferCodec.decode(data)
    }

    func importPreview(from url: URL) throws -> ClipboardImportPreview {
        let items = try importItems(from: url)
        return ClipboardImportPreview(items: items)
    }

    @discardableResult
    func backup(_ items: [ClipboardItem], reason: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension(
                "\(reason)-\(Self.backupTimestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
            )
        // A clip whose image file has gone missing cannot be restored anyway, and
        // failing here would block every import.
        let portableItems: [ClipboardItem] = try items.compactMap { item in
            do {
                return try imageSidecars.portableItem(item)
            } catch ClipboardStorageError.missingImageData {
                return nil
            }
        }
        let document = ClipboardTransferDocument(
            items: portableItems.map(ClipboardTransferItem.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: backupURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        try removeExcessBackups(
            matching: Self.isPreImportBackup,
            keeping: Self.maximumRetainedPreImportBackups
        )
        return backupURL
    }

    func backupInventory() throws -> ClipboardBackupInventory {
        lock.lock()
        defer { lock.unlock() }

        let urls = try backupURLs()
        return ClipboardBackupInventory(
            urls: urls,
            totalByteCount: try urls.reduce(0) { try $0 + byteCount(of: $1) }
        )
    }

    func purgeBackups() throws {
        lock.lock()
        defer { lock.unlock() }

        for url in try backupURLs() {
            try fileManager.removeItem(at: url)
        }
    }

    private func writeHistory(
        _ items: [ClipboardItem],
        richTextFileNames: [UUID: ClipboardRichTextFileNames]
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.userInfo[.clipboardRichTextFileNames] = richTextFileNames

        let data = try encoder.encode(items)
        try faultInjector?(.manifestWrite)
        let stagedURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(".clipboard-history-\(UUID().uuidString).pending")
        defer { try? fileManager.removeItem(at: stagedURL) }
        try data.write(to: stagedURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        try faultInjector?(.manifestWriteCompleted)

        guard rename(stagedURL.path, fileURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    @discardableResult
    private func backupExistingStore(reason: String) -> URL? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let recoveryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "Recovery-\(reason)-\(Self.backupTimestampFormatter.string(from: Date()))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let backupURL = recoveryURL.appendingPathComponent(fileURL.lastPathComponent)
        let sidecarDirectories = [imageDirectoryURL, richTextDirectoryURL].map { directoryURL in
            (
                live: directoryURL,
                quarantined: recoveryURL.appendingPathComponent(
                    directoryURL.lastPathComponent,
                    isDirectory: true
                )
            )
        }

        do {
            try fileManager.createDirectory(at: recoveryURL, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryURL.path)
            try fileManager.moveItem(at: fileURL, to: backupURL)
            for directory in sidecarDirectories
            where fileManager.fileExists(atPath: directory.live.path) {
                try fileManager.moveItem(at: directory.live, to: directory.quarantined)
            }
            for directory in sidecarDirectories {
                try fileManager.createDirectory(at: directory.live, withIntermediateDirectories: true)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.live.path
                )
            }
        } catch {
            for directory in sidecarDirectories
            where fileManager.fileExists(atPath: directory.quarantined.path) {
                // A replacement directory may already exist if the failure came later.
                if (try? fileManager.contentsOfDirectory(atPath: directory.live.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: directory.live)
                }
                if !fileManager.fileExists(atPath: directory.live.path) {
                    try? fileManager.moveItem(at: directory.quarantined, to: directory.live)
                }
            }
            if fileManager.fileExists(atPath: backupURL.path),
               !fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.moveItem(at: backupURL, to: fileURL)
            }
            try? fileManager.removeItem(at: recoveryURL)
            return nil
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        try? removeExcessBackups(
            matching: Self.isRecoveryBackup,
            keeping: Self.maximumRetainedRecoveryFolders
        )
        return recoveryURL
    }

    private func backupURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isDirectoryKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ).filter { url in
            Self.isPreImportBackup(url) || Self.isRecoveryBackup(url)
        }
    }

    private func removeExcessBackups(
        matching predicate: (URL) -> Bool,
        keeping retainedCount: Int
    ) throws {
        let matchingURLs = try backupURLs().filter(predicate)
        let sortedURLs = try matchingURLs.sorted { lhs, rhs in
            let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? .distantPast
            if lhsDate == rhsDate {
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
            return lhsDate > rhsDate
        }
        for url in sortedURLs.dropFirst(retainedCount) {
            try fileManager.removeItem(at: url)
        }
    }

    private func byteCount(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            let childValues = try childURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            if childValues.isRegularFile == true {
                total += Int64(childValues.fileSize ?? 0)
            }
        }
        return total
    }

    private static func isPreImportBackup(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("clipboard-history.pre-import-"),
              name.hasSuffix(".json") else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func isRecoveryBackup(_ url: URL) -> Bool {
        guard url.lastPathComponent.hasPrefix("Recovery-") else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func hasUniqueIdentifiers(_ items: [ClipboardItem]) -> Bool {
        Set(items.map(\.id)).count == items.count
    }

    private static func requiresNormalization(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let records = root as? [[String: Any]] else {
            return false
        }
        let requiredKeys: Set<String> = [
            "id",
            "text",
            "contentKind",
            "createdAt",
            "lastCopiedAt",
            "isPinned",
            "copyCount",
        ]
        return records.contains { !requiredKeys.isSubset(of: Set($0.keys)) }
    }

    private static func defaultAppDirectory(fileManager: FileManager) -> URL {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser

        return supportDirectory.appendingPathComponent("CopyClipLite", isDirectory: true)
    }
}

private final class ClipboardStorageState: @unchecked Sendable {
    private let lock = NSLock()
    private var isProtected = false
    private var hasPendingImageCleanup = false

    var imageCleanupPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasPendingImageCleanup
    }

    func setImageCleanupPending(_ pending: Bool) {
        lock.lock()
        hasPendingImageCleanup = pending
        lock.unlock()
    }

    var writesAreAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isProtected
    }

    func protectWrites() {
        lock.lock()
        isProtected = true
        lock.unlock()
    }

    func allowWrites() {
        lock.lock()
        isProtected = false
        lock.unlock()
    }
}
