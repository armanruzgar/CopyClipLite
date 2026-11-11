import Foundation

enum ClipboardContentKind: String, Codable, Hashable, Sendable {
    case text
    case image
    case link
}

struct ClipboardImagePayload: Codable, Hashable, Sendable {
    var data: Data?
    var fileName: String?
    var thumbnailData: Data?
    var thumbnailFileName: String?
    var width: Int
    var height: Int
    var byteCount: Int
    var contentHash: String?

    enum CodingKeys: String, CodingKey {
        case data, fileName, thumbnailData, thumbnailFileName, width, height, byteCount, contentHash
    }

    init(
        data: Data? = nil,
        fileName: String? = nil,
        thumbnailData: Data? = nil,
        thumbnailFileName: String? = nil,
        width: Int,
        height: Int,
        byteCount: Int? = nil,
        contentHash: String? = nil
    ) {
        self.data = data
        self.fileName = fileName
        self.thumbnailData = thumbnailData
        self.thumbnailFileName = thumbnailFileName
        self.width = max(width, 0)
        self.height = max(height, 0)
        self.byteCount = byteCount ?? data?.count ?? 0
        self.contentHash = contentHash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent(Data.self, forKey: .data)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        thumbnailData = try c.decodeIfPresent(Data.self, forKey: .thumbnailData)
        thumbnailFileName = try c.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        width = max(try c.decodeIfPresent(Int.self, forKey: .width) ?? 0, 0)
        height = max(try c.decodeIfPresent(Int.self, forKey: .height) ?? 0, 0)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? data?.count ?? 0
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        if fileName == nil {
            try c.encodeIfPresent(data, forKey: .data)
        }

        try c.encodeIfPresent(fileName, forKey: .fileName)

        if thumbnailFileName == nil {
            try c.encodeIfPresent(thumbnailData, forKey: .thumbnailData)
        }

        try c.encodeIfPresent(thumbnailFileName, forKey: .thumbnailFileName)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(byteCount, forKey: .byteCount)
        try c.encodeIfPresent(contentHash, forKey: .contentHash)
    }

    var dimensionsText: String {
        guard width > 0, height > 0 else {
            return "Image"
        }

        return "\(width) x \(height)"
    }

    var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    var displayData: Data? {
        thumbnailData ?? data
    }
}

struct ClipboardItem: Identifiable, Codable, Hashable, Sendable {
    static let maximumCopyCount = 1_000_000

    let id: UUID
    private var content: ClipboardContent
    var createdAt: Date
    var lastCopiedAt: Date
    var isPinned: Bool
    var copyCount: Int {
        didSet {
            copyCount = Self.normalizedCopyCount(copyCount)
        }
    }
    var sourceApplication: ClipboardSourceApplication?

    var text: String {
        get { content.text }
        set {
            switch content {
            case var .text(value):
                value.text = newValue
                content = .text(value)
            case var .image(value):
                value.associatedText = newValue
                content = .image(value)
            case .link:
                // A link clip's text is derived from its URL and is not editable.
                break
            }
        }
    }

    var contentKind: ClipboardContentKind {
        content.kind
    }

    var image: ClipboardImagePayload? {
        get {
            guard case let .image(value) = content else { return nil }
            return value.payload
        }
        set {
            switch (content, newValue) {
            case let (_, payload?):
                content = .image(
                    ClipboardImageContent(associatedText: text, payload: payload)
                )
            case let (.image(value), nil):
                content = .text(
                    ClipboardTextContent(
                        text: value.associatedText,
                        rtfData: nil,
                        htmlData: nil
                    )
                )
            case (.text, nil), (.link, nil):
                break
            }
        }
    }

    var link: ClipboardLinkContent? {
        guard case let .link(value) = content else { return nil }
        return value
    }

    var linkURL: URL? {
        link?.url
    }

    var isFileClip: Bool {
        link?.isFileURL == true
    }

    var rtfData: Data? {
        get {
            guard case let .text(value) = content else { return nil }
            return value.rtfData
        }
        set {
            guard case var .text(value) = content else { return }
            value.rtfData = newValue
            content = .text(value)
        }
    }

    var htmlData: Data? {
        get {
            guard case let .text(value) = content else { return nil }
            return value.htmlData
        }
        set {
            guard case var .text(value) = content else { return }
            value.htmlData = newValue
            content = .text(value)
        }
    }

    init(
        id: UUID = UUID(),
        text: String,
        rtfData: Data? = nil,
        htmlData: Data? = nil,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        isPinned: Bool = false,
        copyCount: Int = 1,
        sourceApplication: ClipboardSourceApplication? = nil
    ) {
        self.id = id
        self.content = .text(
            ClipboardTextContent(text: text, rtfData: rtfData, htmlData: htmlData)
        )
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
        self.copyCount = Self.normalizedCopyCount(copyCount)
        self.sourceApplication = sourceApplication
    }

    init(
        id: UUID = UUID(),
        text: String = "",
        image: ClipboardImagePayload,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        isPinned: Bool = false,
        copyCount: Int = 1,
        sourceApplication: ClipboardSourceApplication? = nil
    ) {
        self.id = id
        self.content = .image(
            ClipboardImageContent(associatedText: text, payload: image)
        )
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
        self.copyCount = Self.normalizedCopyCount(copyCount)
        self.sourceApplication = sourceApplication
    }

    init(
        id: UUID = UUID(),
        link: ClipboardLinkContent,
        createdAt: Date = Date(),
        lastCopiedAt: Date = Date(),
        isPinned: Bool = false,
        copyCount: Int = 1,
        sourceApplication: ClipboardSourceApplication? = nil
    ) {
        self.id = id
        self.content = .link(link)
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt
        self.isPinned = isPinned
        self.copyCount = Self.normalizedCopyCount(copyCount)
        self.sourceApplication = sourceApplication
    }

    init(from decoder: Decoder) throws {
        let persisted = try PersistedClipboardItem(from: decoder)
        id = persisted.id ?? UUID()
        let text = persisted.text ?? ""
        let image = persisted.image
        let decodedContentKind = persisted.contentKind
            .flatMap(ClipboardContentKind.init(rawValue:))
        let persistedLink = persisted.linkURL.map {
            ClipboardLinkContent(url: $0, title: persisted.linkTitle)
        }
        let itemID = id
        let resolver = decoder.userInfo[.clipboardRichTextResolver] as? ClipboardRichTextResolver
        func textContent() -> ClipboardContent {
            .text(
                ClipboardTextContent(
                    text: text,
                    rtfData: Self.richText(
                        .rtf,
                        itemID: itemID,
                        inlineData: persisted.rtfData,
                        fileName: persisted.rtfFileName,
                        resolver: resolver
                    ),
                    htmlData: Self.richText(
                        .html,
                        itemID: itemID,
                        inlineData: persisted.htmlData,
                        fileName: persisted.htmlFileName,
                        resolver: resolver
                    )
                )
            )
        }
        switch Self.normalizedContentKind(
            decodedContentKind,
            image: image,
            link: persistedLink
        ) {
        case .text:
            content = textContent()
        case .image:
            if let image {
                content = .image(
                    ClipboardImageContent(associatedText: text, payload: image)
                )
            } else {
                content = textContent()
            }
        case .link:
            content = persistedLink.map(ClipboardContent.link) ?? textContent()
        }
        createdAt = persisted.createdAt ?? Date()
        lastCopiedAt = persisted.lastCopiedAt ?? Date()
        isPinned = persisted.isPinned ?? false
        copyCount = Self.normalizedCopyCount(persisted.copyCount ?? 1)
        sourceApplication = persisted.sourceApplication
    }

    func encode(to encoder: Encoder) throws {
        let fileNames = (
            encoder.userInfo[.clipboardRichTextFileNames] as? [UUID: ClipboardRichTextFileNames]
        )?[id]
        try PersistedClipboardItem(
            id: id,
            text: text,
            contentKind: contentKind.rawValue,
            linkURL: link?.url,
            linkTitle: link?.title,
            image: image,
            rtfData: fileNames?.rtf == nil ? rtfData : nil,
            rtfFileName: fileNames?.rtf,
            htmlData: fileNames?.html == nil ? htmlData : nil,
            htmlFileName: fileNames?.html,
            createdAt: createdAt,
            lastCopiedAt: lastCopiedAt,
            isPinned: isPinned,
            copyCount: copyCount,
            sourceApplication: sourceApplication
        ).encode(to: encoder)
    }

    var previewText: String {
        Self.previewText(contentKind: contentKind, text: text, image: image, link: link)
    }

    var isImage: Bool {
        contentKind == .image && image != nil
    }

    var hasRichText: Bool {
        rtfData != nil || htmlData != nil
    }

    var searchableText: String {
        switch contentKind {
        case .text:
            [text, sourceApplication?.name]
                .compactMap { $0 }
                .joined(separator: " ")
        case .image:
            ["image", image?.dimensionsText, text, sourceApplication?.name]
                .compactMap { $0 }
                .joined(separator: " ")
        case .link:
            [
                isFileClip ? "file" : "link",
                link?.title,
                link?.subtitle,
                text,
                sourceApplication?.name,
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        }
    }

    var metadataText: String {
        let copies = copyCount == 1 ? "1 copy" : "\(copyCount) copies"
        let sourceName = sourceApplication?.name

        switch contentKind {
        case .text:
            let countText = text.count == 1 ? "1 character" : "\(text.count) characters"
            return [countText, copies, sourceName]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .link:
            return [isFileClip ? "File" : "Link", link?.subtitle, copies, sourceName]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .image:
            guard let image else {
                return [copies, sourceName]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            }

            return [image.dimensionsText, image.byteCountText, copies, sourceName]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }

    var lastCopiedDescription: String {
        lastCopiedAt.copyClipRelativeDescription
    }

    private static func normalizedContentKind(
        _ contentKind: ClipboardContentKind?,
        image: ClipboardImagePayload?,
        link: ClipboardLinkContent?
    ) -> ClipboardContentKind {
        if contentKind == .link || (contentKind == nil && link != nil) {
            return link == nil ? .text : .link
        }
        if contentKind == .image || image != nil {
            return image == nil ? .text : .image
        }

        return .text
    }

    private static func richText(
        _ kind: ClipboardRichTextKind,
        itemID: UUID,
        inlineData: Data?,
        fileName: String?,
        resolver: ClipboardRichTextResolver?
    ) -> Data? {
        guard let resolver else { return inlineData }
        return resolver.resolve(kind, itemID: itemID, inlineData: inlineData, fileName: fileName)
    }

    private static func normalizedCopyCount(_ copyCount: Int) -> Int {
        min(max(copyCount, 1), maximumCopyCount)
    }

    private static func previewText(
        contentKind: ClipboardContentKind,
        text: String,
        image: ClipboardImagePayload?,
        link: ClipboardLinkContent?
    ) -> String {
        switch contentKind {
        case .text:
            return text.copyClipPreview(limit: 160)
        case .image:
            let textPreview = text.copyClipPreview(limit: 96)
            return textPreview.isEmpty ? "Image" : "Image · \(textPreview)"
        case .link:
            return (link?.title ?? text).copyClipPreview(limit: 160)
        }
    }
}

private struct PersistedClipboardItem: Codable {
    let id: UUID?
    let text: String?
    let contentKind: String?
    let linkURL: URL?
    let linkTitle: String?
    let image: ClipboardImagePayload?
    let rtfData: Data?
    let rtfFileName: String?
    let htmlData: Data?
    let htmlFileName: String?
    let createdAt: Date?
    let lastCopiedAt: Date?
    let isPinned: Bool?
    let copyCount: Int?
    let sourceApplication: ClipboardSourceApplication?
}
