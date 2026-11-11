import Foundation

struct ClipboardHistoryPolicy: Equatable, Sendable {
    let unpinnedLimit: Int
    let retentionPolicy: ClipboardRetentionPolicy
}

struct ClipboardHistoryPolicyResult: Equatable, Sendable {
    let items: [ClipboardItem]
    let expiredCount: Int
    let overLimitCount: Int
}

enum ClipboardHistoryRules {
    static func applyingPolicy(
        to candidateItems: [ClipboardItem],
        policy: ClipboardHistoryPolicy,
        now: Date
    ) -> ClipboardHistoryPolicyResult {
        var retained = candidateItems.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        let countBeforeExpiration = retained.count
        if let expirationInterval = policy.retentionPolicy.expirationInterval {
            let cutoffDate = now.addingTimeInterval(-expirationInterval)
            retained.removeAll { !$0.isPinned && $0.lastCopiedAt < cutoffDate }
        }
        let expiredCount = countBeforeExpiration - retained.count

        let countBeforeLimit = retained.count
        var unpinnedCount = 0
        retained.removeAll { item in
            guard !item.isPinned else { return false }
            unpinnedCount += 1
            return unpinnedCount > policy.unpinnedLimit
        }
        return ClipboardHistoryPolicyResult(
            items: retained,
            expiredCount: expiredCount,
            overLimitCount: countBeforeLimit - retained.count
        )
    }

    static func merging(
        existing: [ClipboardItem],
        imported: [ClipboardItem]
    ) -> [ClipboardItem] {
        var result = existing

        for importedItem in imported {
            // An earlier content match must not steal an identity already in the list.
            let matchingIndex = result.firstIndex {
                $0.id == importedItem.id
            } ?? result.firstIndex {
                contentMatchesForImport($0, importedItem)
            }
            guard let matchingIndex else {
                result.append(importedItem)
                continue
            }

            let existingItem = result[matchingIndex]
            var preferred = existingItem.lastCopiedAt >= importedItem.lastCopiedAt
                ? existingItem
                : importedItem
            preferred.isPinned = existingItem.isPinned || importedItem.isPinned
            preferred.copyCount = max(existingItem.copyCount, importedItem.copyCount)
            result[matchingIndex] = preferred
        }

        return result.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    static func recordingText(
        _ text: String,
        rtfData: Data?,
        htmlData: Data?,
        sourceApplication: ClipboardSourceApplication?,
        capturedAt: Date,
        in currentItems: [ClipboardItem]
    ) -> [ClipboardItem] {
        var items = currentItems
        if let existingIndex = items.firstIndex(where: {
            $0.contentKind == .text && $0.text == text
        }) {
            var existing = items.remove(at: existingIndex)
            let isNewestRepresentation = capturedAt >= existing.lastCopiedAt
            existing.lastCopiedAt = max(existing.lastCopiedAt, capturedAt)
            existing.copyCount = incrementedCopyCount(existing.copyCount)
            if isNewestRepresentation {
                existing.sourceApplication = sourceApplication ?? existing.sourceApplication
                existing.rtfData = rtfData
                existing.htmlData = htmlData
            }
            insert(existing, byLastCopiedAtInto: &items)
        } else {
            insert(
                ClipboardItem(
                    text: text,
                    rtfData: rtfData,
                    htmlData: htmlData,
                    createdAt: capturedAt,
                    lastCopiedAt: capturedAt,
                    sourceApplication: sourceApplication
                ),
                byLastCopiedAtInto: &items
            )
        }
        return items
    }

    static func recordingImage(
        _ image: ClipboardImagePayload,
        associatedText: String?,
        sourceApplication: ClipboardSourceApplication?,
        capturedAt: Date,
        in currentItems: [ClipboardItem]
    ) -> [ClipboardItem] {
        var items = currentItems
        if let existingIndex = items.firstIndex(where: {
            guard let existingHash = $0.image?.contentHash,
                  let newHash = image.contentHash else {
                return false
            }
            return existingHash == newHash
        }) {
            var existing = items.remove(at: existingIndex)
            let isNewestRepresentation = capturedAt >= existing.lastCopiedAt
            existing.lastCopiedAt = max(existing.lastCopiedAt, capturedAt)
            existing.copyCount = incrementedCopyCount(existing.copyCount)
            if isNewestRepresentation {
                existing.sourceApplication = sourceApplication ?? existing.sourceApplication
                existing.text = associatedText ?? ""
                existing.image = image
            }
            items.insert(existing, at: 0)
        } else {
            items.insert(
                ClipboardItem(
                    text: associatedText ?? "",
                    image: image,
                    createdAt: capturedAt,
                    lastCopiedAt: capturedAt,
                    sourceApplication: sourceApplication
                ),
                at: 0
            )
        }
        return items.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    static func recordingLink(
        _ link: ClipboardLinkContent,
        sourceApplication: ClipboardSourceApplication?,
        capturedAt: Date,
        in currentItems: [ClipboardItem]
    ) -> [ClipboardItem] {
        var items = currentItems
        if let existingIndex = items.firstIndex(where: { $0.linkURL == link.url }) {
            var existing = items.remove(at: existingIndex)
            let isNewestRepresentation = capturedAt >= existing.lastCopiedAt
            existing.lastCopiedAt = max(existing.lastCopiedAt, capturedAt)
            existing.copyCount = incrementedCopyCount(existing.copyCount)
            if isNewestRepresentation {
                existing.sourceApplication = sourceApplication ?? existing.sourceApplication
            }
            insert(existing, byLastCopiedAtInto: &items)
        } else {
            insert(
                ClipboardItem(
                    link: link,
                    createdAt: capturedAt,
                    lastCopiedAt: capturedAt,
                    sourceApplication: sourceApplication
                ),
                byLastCopiedAtInto: &items
            )
        }
        return items
    }

    /// Records several links copied together. They share one capture time, so the
    /// first link ends up on top, matching the order they were copied in.
    static func recordingLinks(
        _ links: [ClipboardLinkContent],
        sourceApplication: ClipboardSourceApplication?,
        capturedAt: Date,
        in currentItems: [ClipboardItem]
    ) -> [ClipboardItem] {
        links.reversed().reduce(currentItems) { items, link in
            recordingLink(
                link,
                sourceApplication: sourceApplication,
                capturedAt: capturedAt,
                in: items
            )
        }
    }

    /// A capture recorded after a newer in-app copy belongs below it, not on top.
    /// Ties go first, so in-order captures still land at index 0.
    private static func insert(
        _ item: ClipboardItem,
        byLastCopiedAtInto items: inout [ClipboardItem]
    ) {
        let index = items.firstIndex { $0.lastCopiedAt <= item.lastCopiedAt } ?? items.endIndex
        items.insert(item, at: index)
    }

    private static func contentMatchesForImport(
        _ existingItem: ClipboardItem,
        _ importedItem: ClipboardItem
    ) -> Bool {
        guard existingItem.contentKind == importedItem.contentKind else { return false }
        switch importedItem.contentKind {
        case .text:
            return existingItem.text == importedItem.text
        case .image:
            guard let importedHash = importedItem.image?.contentHash else { return false }
            return existingItem.image?.contentHash == importedHash
        case .link:
            return existingItem.linkURL == importedItem.linkURL
        }
    }

    private static func incrementedCopyCount(_ copyCount: Int) -> Int {
        guard copyCount < ClipboardItem.maximumCopyCount else {
            return ClipboardItem.maximumCopyCount
        }
        return max(copyCount + 1, 1)
    }
}
