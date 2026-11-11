import AppKit
import Foundation
import UniformTypeIdentifiers

protocol ClipboardCapturePasteboard {
    func data(forType dataType: NSPasteboard.PasteboardType) -> Data?
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
    /// One string per pasteboard item. `string(forType:)` only reads the first item.
    func itemStrings(forType dataType: NSPasteboard.PasteboardType) -> [String]
}

extension ClipboardCapturePasteboard {
    func itemStrings(forType dataType: NSPasteboard.PasteboardType) -> [String] {
        string(forType: dataType).map { [$0] } ?? []
    }
}

extension NSPasteboard: ClipboardCapturePasteboard {
    func itemStrings(forType dataType: NSPasteboard.PasteboardType) -> [String] {
        pasteboardItems?.compactMap { $0.string(forType: dataType) } ?? []
    }
}

struct CapturedTextSnapshot: Sendable {
    let text: String
    let rtfData: Data?
    let htmlData: Data?
}

struct CapturedTextResult: Sendable {
    let snapshot: CapturedTextSnapshot?
    let warning: String?
}

extension ClipboardImageCandidate {
    var hasFileURLSource: Bool {
        sources.contains {
            if case .fileURL = $0 { return true }
            return false
        }
    }
}

enum ClipboardCaptureReader {
    static let maximumCapturedFiles = 50
    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    static func text(from pasteboard: ClipboardCapturePasteboard) -> CapturedTextResult {
        let rawRTFData = pasteboard.data(forType: .rtf)
        let rawHTMLData = pasteboard.data(forType: .html)
        let rtfData = rawRTFData.flatMap {
            $0.count <= ClipboardStorage.maximumImportedRichTextBytes ? $0 : nil
        }
        let htmlData = rawHTMLData.flatMap {
            $0.count <= ClipboardStorage.maximumImportedRichTextBytes ? $0 : nil
        }
        let droppedFormats = [
            rawRTFData != nil && rtfData == nil ? "RTF" : nil,
            rawHTMLData != nil && htmlData == nil ? "HTML" : nil
        ].compactMap { $0 }
        let warning = droppedFormats.isEmpty
            ? nil
            : "The text was saved without oversized \(droppedFormats.joined(separator: " and ")) formatting."
        let text = pasteboard.string(forType: .string)
            ?? rtfPlainText(data: rtfData)
            ?? htmlData.map(ClipboardHTMLTextExtractor.plainText(from:))

        guard let text,
              text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else {
            return CapturedTextResult(snapshot: nil, warning: warning)
        }
        guard text.count <= ClipboardStorage.maximumImportedTextCharacters else {
            return CapturedTextResult(
                snapshot: nil,
                warning: "A text clip was skipped because it exceeds 20,000 characters."
            )
        }

        return CapturedTextResult(
            snapshot: CapturedTextSnapshot(text: text, rtfData: rtfData, htmlData: htmlData),
            warning: warning
        )
    }

    /// Office apps put a rendered picture next to the text they copy. When the
    /// copy carries real text and rich text, the text is what the user copied.
    static func hasRichTextCopy(
        _ pasteboard: ClipboardCapturePasteboard,
        snapshot: CapturedTextSnapshot?
    ) -> Bool {
        guard let snapshot,
              snapshot.rtfData != nil || snapshot.htmlData != nil,
              let plainText = pasteboard.string(forType: .string) else {
            return false
        }
        return plainText.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
    }

    /// Every file URL on the pasteboard, one per pasteboard item, in order.
    static func fileURLs(from pasteboard: ClipboardCapturePasteboard) -> [URL] {
        var seen = Set<URL>()
        return pasteboard.itemStrings(forType: .fileURL).compactMap { string in
            guard let url = URL(string: string), url.isFileURL else { return nil }
            let normalizedURL = normalizedFileURL(url)
            return seen.insert(normalizedURL).inserted ? normalizedURL : nil
        }
    }

    static func fileLink(for fileURL: URL) -> ClipboardLinkContent {
        let name = fileURL.lastPathComponent
        return ClipboardLinkContent(
            url: fileURL,
            title: name.isEmpty ? nil : name
        )
    }

    static func image(from pasteboard: ClipboardCapturePasteboard) -> ClipboardImageCandidate? {
        var sources: [ClipboardImageCandidateSource] = []
        if let data = pasteboard.data(forType: .png) {
            sources.append(.data(data, isPNG: true))
        }
        if let data = pasteboard.data(forType: .tiff) {
            sources.append(.data(data, isPNG: false))
        }
        for type in [
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif")
        ] {
            if let data = pasteboard.data(forType: type) {
                sources.append(.data(data, isPNG: false))
            }
        }
        let fileURLs = fileURLs(from: pasteboard)
        if fileURLs.count == 1,
           let fileURL = fileURLs.first,
           isImageFile(fileURL) {
            sources.append(.fileURL(fileURL))
        }
        return sources.isEmpty ? nil : ClipboardImageCandidate(sources: sources)
    }

    /// A file copied in Finder, or a link copied from a browser. Image files are
    /// deliberately excluded: they belong to the image pipeline, which normalizes
    /// them to PNG so the clip survives the original file being moved or deleted.
    static func link(from pasteboard: ClipboardCapturePasteboard) -> ClipboardLinkContent? {
        let fileURLs = fileURLs(from: pasteboard)
        if fileURLs.count == 1,
           let fileURL = fileURLs.first,
           !isImageFile(fileURL) {
            return fileLink(for: fileURL)
        }
        guard let urlString = pasteboard.string(forType: .URL),
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        let title = pasteboard.string(forType: urlNameType)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty, title != urlString, title != url.absoluteString else {
            return ClipboardLinkContent(url: url, title: nil)
        }
        return ClipboardLinkContent(url: url, title: title)
    }

    /// Finder may hand out `file:///.file/id=…` reference URLs, whose path is meaningless.
    private static func normalizedFileURL(_ url: URL) -> URL {
        ((url as NSURL).filePathURL ?? url).standardizedFileURL
    }

    private static func isImageFile(_ url: URL) -> Bool {
        let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if resourceType?.conforms(to: .image) == true
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            return true
        }
        return knownImageFileExtensions.contains(url.pathExtension.lowercased())
    }

    private static let knownImageFileExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "icns", "jp2", "jpeg", "jpg", "png",
        "psd", "tif", "tiff", "webp"
    ]

    private static func rtfPlainText(data: Data?) -> String? {
        guard let data else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ).string
    }
}

/// Reads the visible text of an HTML fragment without a web view, so nothing is
/// ever fetched. It is a fallback for clipboards that carry no plain text.
enum ClipboardHTMLTextExtractor {
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™",
        "bull": "•", "middot": "·", "euro": "€"
    ]

    static func plainText(from data: Data) -> String {
        plainText(fromHTML: String(decoding: data, as: UTF8.self))
    }

    static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [
            "<!--[\\s\\S]*?-->",
            "<script\\b[^>]*>[\\s\\S]*?</script\\s*>",
            "<style\\b[^>]*>[\\s\\S]*?</style\\s*>",
            "<head\\b[^>]*>[\\s\\S]*?</head\\s*>"
        ] {
            text = replacing(pattern, in: text, with: " ")
        }
        text = replacing(
            "<(br|/p|/div|/li|/tr|/h[1-6]|/blockquote|/pre|/table)\\b[^>]*>",
            in: text,
            with: "\n"
        )
        text = replacing("<(/td|/th|img|hr)\\b[^>]*>", in: text, with: " ")
        text = replacing("<[^>]*>", in: text, with: "")
        text = decodingEntities(in: text)

        return text
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func decodingEntities(in text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let entity = String(text[text.index(after: index)..<semicolon])
            if let decoded = decodedEntity(entity) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decodedEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let scalarValue: UInt32?
            if digits.first == "x" || digits.first == "X" {
                scalarValue = UInt32(digits.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(digits, radix: 10)
            }
            return scalarValue.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[entity] ?? namedEntities[entity.lowercased()]
    }
}
