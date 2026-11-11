import AppKit
import Foundation

enum ClipboardCaptureContent: Sendable {
    case files([URL])
    case image(ClipboardImageCandidate, associatedText: CapturedTextSnapshot?)
    /// Every image representation exceeded the processor's input limit.
    case oversizedImage(associatedText: CapturedTextSnapshot?)
    case link(ClipboardLinkContent)
    case text(CapturedTextSnapshot)
    case empty
}

struct ClipboardCaptureSnapshot: Sendable {
    let content: ClipboardCaptureContent
    let textWarning: String?
}

extension ClipboardCaptureReader {
    static func snapshot(from pasteboard: ClipboardCapturePasteboard) -> ClipboardCaptureSnapshot {
        let capturedText = text(from: pasteboard)
        let fileURLs = fileURLs(from: pasteboard)
        if fileURLs.count > 1 {
            return ClipboardCaptureSnapshot(content: .files(fileURLs), textWarning: capturedText.warning)
        }

        let hasImageFile = fileURLs.count == 1 && isImageFile(fileURLs[0])
        // A rich-text copy only becomes an image clip through a copied image file,
        // so the (possibly large) image data is not read at all otherwise.
        if hasImageFile || !hasRichTextCopy(pasteboard, snapshot: capturedText.snapshot) {
            let imageRead = imageRead(from: pasteboard, fileURLs: fileURLs)
            if let candidate = imageRead.candidate {
                return ClipboardCaptureSnapshot(
                    content: .image(candidate, associatedText: capturedText.snapshot),
                    textWarning: capturedText.warning
                )
            }
            if imageRead.skippedOversizedRepresentation {
                return ClipboardCaptureSnapshot(
                    content: .oversizedImage(associatedText: capturedText.snapshot),
                    textWarning: capturedText.warning
                )
            }
        }

        if let link = link(from: pasteboard, fileURLs: fileURLs) {
            return ClipboardCaptureSnapshot(content: .link(link), textWarning: capturedText.warning)
        }
        guard let textSnapshot = capturedText.snapshot else {
            return ClipboardCaptureSnapshot(content: .empty, textWarning: capturedText.warning)
        }
        return ClipboardCaptureSnapshot(content: .text(textSnapshot), textWarning: capturedText.warning)
    }
}

enum ClipboardCaptureExecution: Sendable {
    /// Reads on the calling actor; the snapshot is recorded before the poll returns.
    case inline
    /// Reads on a serial background queue and records after hopping back to the main actor.
    case background
}

/// Serialises every read of the pasteboard it owns behind `lock`, on one serial
/// queue, so completions reach the main queue in the order the reads were issued.
final class ClipboardCaptureReadQueue: @unchecked Sendable {
    private let pasteboard: any ClipboardStorePasteboard
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "CopyClipLite.ClipboardCaptureRead",
        qos: .userInitiated
    )

    init(pasteboard: any ClipboardStorePasteboard) {
        self.pasteboard = pasteboard
    }

    /// Delivers nil when the pasteboard changed after `expectedChangeCount` was observed.
    func read(
        expectedChangeCount: Int,
        completion: @escaping @MainActor @Sendable (ClipboardCaptureSnapshot?) -> Void
    ) {
        queue.async { [self] in
            let snapshot = lock.withLock { () -> ClipboardCaptureSnapshot? in
                guard pasteboard.changeCount == expectedChangeCount else { return nil }
                let snapshot = ClipboardCaptureReader.snapshot(from: pasteboard)
                return pasteboard.changeCount == expectedChangeCount ? snapshot : nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(snapshot)
                }
            }
        }
    }
}
