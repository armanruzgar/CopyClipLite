import AppKit
import Foundation
import UniformTypeIdentifiers

private final class ClipboardDragDataCompletion: @unchecked Sendable {
    private let completion: (Data?, Error?) -> Void

    init(_ completion: @escaping (Data?, Error?) -> Void) {
        self.completion = completion
    }

    func callAsFunction(_ data: Data?, _ error: Error?) {
        completion(data, error)
    }
}

private final class ClipboardDragFileCompletion: @unchecked Sendable {
    private let completion: (URL?, Bool, Error?) -> Void

    init(_ completion: @escaping (URL?, Bool, Error?) -> Void) {
        self.completion = completion
    }

    func callAsFunction(_ url: URL?, _ isInPlace: Bool, _ error: Error?) {
        completion(url, isInPlace, error)
    }
}

final class ClipboardDragFileStager: @unchecked Sendable {
    private let imageReader: any ClipboardImageReading
    private let item: ClipboardItem
    private let fileManager: FileManager
    private let stagingRoot: URL
    private let sessionDirectory: URL
    private let lock = NSLock()
    private var stagedURL: URL?

    init(
        imageReader: any ClipboardImageReading,
        item: ClipboardItem,
        stagingRoot: URL,
        fileManager: FileManager
    ) {
        self.imageReader = imageReader
        self.item = item
        self.fileManager = fileManager
        self.stagingRoot = stagingRoot
        self.sessionDirectory = stagingRoot.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
    }

    deinit {
        try? fileManager.removeItem(at: sessionDirectory)
    }

    func fileURL() throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        if let stagedURL,
           fileManager.fileExists(atPath: stagedURL.path) {
            return stagedURL
        }
        guard let data = imageReader.imageData(for: item) else {
            throw ClipboardStorageError.missingImageData
        }
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stagingRoot.path
        )
        try fileManager.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sessionDirectory.path
        )
        let url = sessionDirectory.appendingPathComponent("CopyClip-Image.png")
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        stagedURL = url
        return url
    }
}

struct ClipboardDragProviderFactory {
    /// Where the installed app stages image files for drags: `$TMPDIR/CopyClipLite-Drag`.
    /// Creating a factory empties its staging directory, so anything that is not the
    /// running app (tests in particular) must pass a directory of its own instead.
    static var defaultStagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "CopyClipLite-Drag",
            isDirectory: true
        )
    }

    private let imageReader: any ClipboardImageReading
    private let fileManager: FileManager
    private let stagingDirectory: URL

    init(
        imageReader: any ClipboardImageReading,
        fileManager: FileManager = .default,
        stagingDirectory: URL
    ) {
        self.imageReader = imageReader
        self.fileManager = fileManager
        self.stagingDirectory = stagingDirectory
        Self.prepareStagingDirectory(
            self.stagingDirectory,
            fileManager: fileManager
        )
    }

    @MainActor
    func provider(for item: ClipboardItem) -> NSItemProvider {
        switch item.contentKind {
        case .text:
            return textProvider(for: item)
        case .image:
            return imageProvider(for: item)
        case .link:
            return linkProvider(for: item)
        }
    }

    @MainActor
    private func linkProvider(for item: ClipboardItem) -> NSItemProvider {
        guard let link = item.link else {
            return NSItemProvider(object: item.text as NSString)
        }
        // A file clip already points at a real file, so hand the receiver the URL
        // itself rather than staging a copy the way image clips have to.
        let provider = NSItemProvider(object: link.url as NSURL)
        provider.suggestedName = link.isFileURL
            ? link.url.lastPathComponent
            : (link.subtitle ?? link.url.lastPathComponent)
        return provider
    }

    @MainActor
    private func textProvider(for item: ClipboardItem) -> NSItemProvider {
        let provider = NSItemProvider(object: item.text as NSString)
        provider.suggestedName = "CopyClip Text"
        if let rtfData = item.rtfData {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.rtf.identifier,
                visibility: .all
            ) { completion in
                completion(rtfData, nil)
                return nil
            }
        }
        if let htmlData = item.htmlData {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.html.identifier,
                visibility: .all
            ) { completion in
                completion(htmlData, nil)
                return nil
            }
        }
        return provider
    }

    @MainActor
    private func imageProvider(for item: ClipboardItem) -> NSItemProvider {
        let imageReader = imageReader
        let stager = ClipboardDragFileStager(
            imageReader: imageReader,
            item: item,
            stagingRoot: stagingDirectory,
            fileManager: fileManager
        )
        let provider = NSItemProvider()
        provider.suggestedName = "CopyClip Image.png"
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            visibility: .all
        ) { completion in
            let completion = ClipboardDragDataCompletion(completion)
            DispatchQueue.global(qos: .utility).async {
                let data = imageReader.imageData(for: item)
                completion(data, data == nil ? ClipboardStorageError.missingImageData : nil)
            }
            return nil
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.png.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let completion = ClipboardDragFileCompletion(completion)
            DispatchQueue.global(qos: .utility).async {
                do {
                    completion(try stager.fileURL(), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        // Finder requests a file URL representation when resolving a drag.
        // Register it lazily so beginning the gesture never performs disk I/O
        // on the main actor.
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            let completion = ClipboardDragDataCompletion(completion)
            DispatchQueue.global(qos: .utility).async {
                do {
                    completion(try stager.fileURL().dataRepresentation, nil)
                } catch {
                    completion(nil, error)
                }
            }
            return nil
        }
        return provider
    }

    private static func prepareStagingDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) {
        if let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            try? fileManager.removeItem(at: directory)
        } else if let staleItems = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for staleItem in staleItems {
                try? fileManager.removeItem(at: staleItem)
            }
        }
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }
}
