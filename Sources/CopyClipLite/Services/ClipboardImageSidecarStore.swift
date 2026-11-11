import Foundation

struct ClipboardImageSidecarStore: @unchecked Sendable {
    let directoryURL: URL
    private let fileManager: FileManager
    private let faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)?

    init(
        directoryURL: URL,
        fileManager: FileManager,
        faultInjector: ((ClipboardStorageFaultPoint) throws -> Void)?
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    func imageData(for item: ClipboardItem) -> Data? {
        guard let image = item.image else { return nil }
        if let data = image.data { return data }
        guard let fileName = image.fileName,
              let url = safeURL(for: fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    func isMissingImageData(for item: ClipboardItem) -> Bool {
        guard let image = item.image, image.data == nil else { return false }
        guard let fileName = image.fileName,
              let url = safeURL(for: fileName),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return true
        }
        return values.isRegularFile != true
    }

    func thumbnailData(for item: ClipboardItem) -> Data? {
        guard let image = item.image else { return nil }
        if let data = image.thumbnailData { return data }
        guard let fileName = image.thumbnailFileName,
              let url = safeURL(for: fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    func thumbnailDataRepairingIfNeeded(for item: ClipboardItem) -> ClipboardThumbnailResult? {
        guard let image = item.image else { return nil }
        if let data = image.thumbnailData,
           ClipboardImageProcessor.isDecodableImage(data) {
            let fileName = image.thumbnailFileName
                ?? "\(item.id.uuidString)-thumb-\(ClipboardImageProcessor.contentHash(for: data)).png"
            return ClipboardThumbnailResult(data: data, fileName: fileName)
        }
        if let fileName = image.thumbnailFileName,
           let url = safeURL(for: fileName),
           let data = try? Data(contentsOf: url),
           ClipboardImageProcessor.isDecodableImage(data) {
            return ClipboardThumbnailResult(data: data, fileName: fileName)
        }
        guard let fullData = image.data ?? imageData(for: item),
              let repaired = try? ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: fullData, isPNG: true)
              ),
              let thumbnailData = repaired.thumbnailData else {
            return nil
        }
        let fileName = "\(item.id.uuidString)-thumb-\(ClipboardImageProcessor.contentHash(for: thumbnailData)).png"
        guard let url = safeURL(for: fileName),
              (try? write(thumbnailData, to: url)) != nil else { return nil }
        return ClipboardThumbnailResult(data: thumbnailData, fileName: fileName)
    }

    @discardableResult
    func externalizeImages(
        in items: inout [ClipboardItem],
        newlyCreatedFiles: inout Set<URL>
    ) throws -> Bool {
        var didChange = false
        for index in items.indices {
            guard var image = items[index].image else { continue }
            if let data = image.data {
                let hash = ClipboardImageProcessor.contentHash(for: data)
                let fileName = "\(items[index].id.uuidString)-\(hash).png"
                guard let url = safeURL(for: fileName) else {
                    throw ClipboardStorageError.persistenceFailed
                }
                try write(data, to: url, newlyCreatedFiles: &newlyCreatedFiles)
                image.fileName = fileName
                image.data = nil
                image.contentHash = hash
                didChange = true
            }
            if let thumbnailData = image.thumbnailData {
                let hash = ClipboardImageProcessor.contentHash(for: thumbnailData)
                let fileName = "\(items[index].id.uuidString)-thumb-\(hash).png"
                guard let url = safeURL(for: fileName) else {
                    throw ClipboardStorageError.persistenceFailed
                }
                try write(thumbnailData, to: url, newlyCreatedFiles: &newlyCreatedFiles)
                image.thumbnailFileName = fileName
                image.thumbnailData = nil
                didChange = true
            }
            items[index].image = image
        }
        return didChange
    }

    @discardableResult
    func hydrateMetadata(in items: inout [ClipboardItem]) -> Bool {
        var didChange = false
        for index in items.indices {
            guard var image = items[index].image,
                  let fileName = image.fileName,
                  let imageURL = safeURL(for: fileName),
                  let fullData = try? Data(contentsOf: imageURL) else { continue }
            if image.byteCount == 0 {
                image.byteCount = fullData.count
                didChange = true
            }
            if image.contentHash == nil {
                image.contentHash = (
                    try? ClipboardImageProcessor.process(
                        ClipboardImageCandidate(data: fullData, isPNG: true)
                    ).contentHash
                ) ?? ClipboardImageProcessor.contentHash(for: fullData)
                didChange = true
            }
            let thumbnailIsUsable: Bool
            if let thumbnailData = image.thumbnailData {
                thumbnailIsUsable = ClipboardImageProcessor.isDecodableImage(thumbnailData)
            } else if let thumbnailFileName = image.thumbnailFileName,
                      let thumbnailURL = safeURL(for: thumbnailFileName),
                      let thumbnailData = try? Data(contentsOf: thumbnailURL) {
                thumbnailIsUsable = ClipboardImageProcessor.isDecodableImage(thumbnailData)
            } else {
                thumbnailIsUsable = false
            }
            if !thumbnailIsUsable,
               let repaired = try? ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: fullData, isPNG: true)
               ),
               let thumbnailData = repaired.thumbnailData {
                let hash = ClipboardImageProcessor.contentHash(for: thumbnailData)
                let fileName = "\(items[index].id.uuidString)-thumb-\(hash).png"
                if let thumbnailURL = safeURL(for: fileName),
                   (try? write(thumbnailData, to: thumbnailURL)) != nil {
                    image.thumbnailFileName = fileName
                    image.thumbnailData = nil
                    didChange = true
                }
            }
            items[index].image = image
        }
        return didChange
    }

    func portableItem(_ item: ClipboardItem) throws -> ClipboardItem {
        guard let storedImage = item.image else { return item }
        var portable = item
        guard let fullData = storedImage.data ?? imageData(for: item) else {
            throw ClipboardStorageError.missingImageData
        }
        do {
            portable.image = try ClipboardImageProcessor.process(
                ClipboardImageCandidate(data: fullData, isPNG: true)
            )
        } catch {
            throw ClipboardStorageError.incompatibleExport(
                "an image clip is not a valid canonical PNG"
            )
        }
        return portable
    }

    func removeUnreferencedFiles(keeping items: [ClipboardItem]) throws {
        let fileNames = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
        let referenced = Set(items.flatMap {
            [$0.image?.fileName, $0.image?.thumbnailFileName].compactMap { $0 }
        })
        var firstError: Error?
        for fileName in fileNames where !referenced.contains(fileName) {
            do {
                try fileManager.removeItem(at: directoryURL.appendingPathComponent(fileName))
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    func removeFiles(_ urls: Set<URL>) {
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try faultInjector?(.imageWrite)
        try data.write(to: url, options: [.atomic])
        try faultInjector?(.imageWriteCompleted)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func write(
        _ data: Data,
        to url: URL,
        newlyCreatedFiles: inout Set<URL>
    ) throws {
        let existedBeforeWrite = fileManager.fileExists(atPath: url.path)
        try faultInjector?(.imageWrite)
        try data.write(to: url, options: [.atomic])
        if !existedBeforeWrite {
            newlyCreatedFiles.insert(url.standardizedFileURL)
        }
        try faultInjector?(.imageWriteCompleted)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func safeURL(for fileName: String) -> URL? {
        ClipboardSidecarPath.safeURL(for: fileName, in: directoryURL)
    }
}
