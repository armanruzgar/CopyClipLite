import Foundation

enum ClipboardRichTextKind: String, Hashable, Sendable {
    case rtf
    case html
}

/// Sidecar file names for one clip's rich text. Kept out of `ClipboardItem` so the
/// in-memory model, and its equality, never depends on how the manifest stores it.
struct ClipboardRichTextFileNames: Hashable, Sendable {
    var rtf: String?
    var html: String?

    subscript(kind: ClipboardRichTextKind) -> String? {
        get {
            switch kind {
            case .rtf: rtf
            case .html: html
            }
        }
        set {
            switch kind {
            case .rtf: rtf = newValue
            case .html: html = newValue
            }
        }
    }
}

extension CodingUserInfoKey {
    /// `[UUID: ClipboardRichTextFileNames]`: when present, rich text is encoded by file name.
    static let clipboardRichTextFileNames = CodingUserInfoKey(
        rawValue: "CopyClipLite.richTextFileNames"
    )!
    /// A `ClipboardRichTextResolver` that loads rich text referenced by file name.
    static let clipboardRichTextResolver = CodingUserInfoKey(
        rawValue: "CopyClipLite.richTextResolver"
    )!
}

/// Loads manifest-referenced rich text while `ClipboardItem`s decode, and records
/// what the manifest referenced so storage can tell whether it needs rewriting.
final class ClipboardRichTextResolver: @unchecked Sendable {
    struct LoadedFile {
        let data: Data
        let fileName: String
    }

    private let lock = NSLock()
    private let readFile: (String) -> Data?
    private var manifestFileNames: [UUID: ClipboardRichTextFileNames] = [:]
    private var loaded: [ClipboardRichTextCacheKey: LoadedFile] = [:]

    init(readFile: @escaping (String) -> Data?) {
        self.readFile = readFile
    }

    var referencedFileNames: [UUID: ClipboardRichTextFileNames] {
        lock.withLock { manifestFileNames }
    }

    var loadedFiles: [ClipboardRichTextCacheKey: LoadedFile] {
        lock.withLock { loaded }
    }

    func resolve(
        _ kind: ClipboardRichTextKind,
        itemID: UUID,
        inlineData: Data?,
        fileName: String?
    ) -> Data? {
        if let inlineData { return inlineData }
        guard let fileName else { return nil }
        lock.withLock { manifestFileNames[itemID, default: .init()][kind] = fileName }
        guard let data = readFile(fileName) else { return nil }
        lock.withLock {
            loaded[ClipboardRichTextCacheKey(itemID: itemID, kind: kind)] = LoadedFile(
                data: data,
                fileName: fileName
            )
        }
        return data
    }
}

struct ClipboardRichTextCacheKey: Hashable, Sendable {
    let itemID: UUID
    let kind: ClipboardRichTextKind
}

struct ClipboardRichTextSidecarStore: @unchecked Sendable {
    let directoryURL: URL
    private let fileManager: FileManager
    private let faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)?
    private let hashCache = ClipboardRichTextHashCache()

    init(
        directoryURL: URL,
        fileManager: FileManager,
        faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)?
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func makeResolver() -> ClipboardRichTextResolver {
        ClipboardRichTextResolver { fileName in
            guard let url = safeURL(for: fileName) else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    /// Seeds the hash cache with files just read, so the next save does not rehash them.
    func remember(_ resolver: ClipboardRichTextResolver) {
        hashCache.merge(resolver.loadedFiles.mapValues { ($0.data, $0.fileName) })
    }

    /// Writes any rich text not already on disk and returns the file names the
    /// manifest should reference in place of the bytes.
    func externalize(
        _ items: [ClipboardItem],
        newlyCreatedFiles: inout Set<URL>
    ) throws -> [UUID: ClipboardRichTextFileNames] {
        var fileNames: [UUID: ClipboardRichTextFileNames] = [:]
        var cacheEntries: [ClipboardRichTextCacheKey: (Data, String)] = [:]
        for item in items {
            for (kind, data) in [(ClipboardRichTextKind.rtf, item.rtfData), (.html, item.htmlData)] {
                guard let data else { continue }
                let key = ClipboardRichTextCacheKey(itemID: item.id, kind: kind)
                let fileName = hashCache.fileName(for: key, data: data)
                    ?? "\(item.id.uuidString)-\(ClipboardImageProcessor.contentHash(for: data)).\(kind.rawValue)"
                guard let url = safeURL(for: fileName) else {
                    throw ClipboardStorageError.persistenceFailed
                }
                if !isStored(data, at: url) {
                    try write(data, to: url, newlyCreatedFiles: &newlyCreatedFiles)
                }
                fileNames[item.id, default: .init()][kind] = fileName
                cacheEntries[key] = (data, fileName)
            }
        }
        hashCache.replace(with: cacheEntries)
        return fileNames
    }

    func removeUnreferencedFiles(keeping fileNames: [UUID: ClipboardRichTextFileNames]) throws {
        let storedNames = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
        let referenced = Set(fileNames.values.flatMap { [$0.rtf, $0.html].compactMap { $0 } })
        var firstError: Error?
        for fileName in storedNames where !referenced.contains(fileName) {
            do {
                try fileManager.removeItem(at: directoryURL.appendingPathComponent(fileName))
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func isStored(_ data: Data, at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && values.fileSize == data.count
    }

    private func write(
        _ data: Data,
        to url: URL,
        newlyCreatedFiles: inout Set<URL>
    ) throws {
        let existedBeforeWrite = fileManager.fileExists(atPath: url.path)
        try faultInjector?(.richTextWrite)
        try data.write(to: url, options: [.atomic])
        if !existedBeforeWrite {
            newlyCreatedFiles.insert(url.standardizedFileURL)
        }
        try faultInjector?(.richTextWriteCompleted)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func safeURL(for fileName: String) -> URL? {
        ClipboardSidecarPath.safeURL(for: fileName, in: directoryURL)
    }
}

/// Remembers which file name each clip's rich text hashed to, so a save only has to
/// compare bytes instead of rehashing up to 10 MB per field on every clipboard change.
private final class ClipboardRichTextHashCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ClipboardRichTextCacheKey: (data: Data, fileName: String)] = [:]

    func fileName(for key: ClipboardRichTextCacheKey, data: Data) -> String? {
        lock.withLock {
            guard let entry = entries[key], entry.data == data else { return nil }
            return entry.fileName
        }
    }

    func merge(_ newEntries: [ClipboardRichTextCacheKey: (Data, String)]) {
        lock.withLock {
            for (key, entry) in newEntries {
                entries[key] = (entry.0, entry.1)
            }
        }
    }

    func replace(with newEntries: [ClipboardRichTextCacheKey: (Data, String)]) {
        lock.withLock {
            entries = newEntries.mapValues { (data: $0.0, fileName: $0.1) }
        }
    }
}

enum ClipboardSidecarPath {
    /// Resolves a manifest-supplied file name strictly inside `directoryURL`.
    static func safeURL(for fileName: String, in directoryURL: URL) -> URL? {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\"),
              URL(fileURLWithPath: fileName).lastPathComponent == fileName else {
            return nil
        }
        let baseURL = directoryURL.standardizedFileURL
        let candidateURL = baseURL.appendingPathComponent(
            fileName,
            isDirectory: false
        ).standardizedFileURL
        guard candidateURL.deletingLastPathComponent() == baseURL else { return nil }
        return candidateURL
    }
}
