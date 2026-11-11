import AppKit
import Foundation

struct CopyClipVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let normalized: Substring
        if value.first == "v" || value.first == "V" {
            normalized = value.dropFirst()
        } else {
            normalized = value[...]
        }
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]),
              let minor = Int(components[1]) else {
            return nil
        }
        let patch = components.count == 3 ? Int(components[2]) : 0
        guard let patch else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: CopyClipVersion, rhs: CopyClipVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct CopyClipRelease: Sendable, Equatable {
    let version: String
    let url: URL
}

protocol UpdateFeedLoading: Sendable {
    func latestRelease(from url: URL, userAgent: String) async throws -> CopyClipRelease
}

protocol UpdateHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionUpdateHTTPDataLoader: UpdateHTTPDataLoading {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: UpdateFeedError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data, response))
            }.resume()
        }
    }
}

final class GitHubUpdateFeedLoader: UpdateFeedLoading, @unchecked Sendable {
    private static let releaseAssetName = "CopyClip-Lite-macOS.zip"
    private let httpLoader: any UpdateHTTPDataLoading

    init(httpLoader: any UpdateHTTPDataLoading = URLSessionUpdateHTTPDataLoader()) {
        self.httpLoader = httpLoader
    }

    func latestRelease(from url: URL, userAgent: String) async throws -> CopyClipRelease {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpLoader.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateFeedError.invalidResponse
        }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateFeedError.invalidResponse
        }
        let version: String
        if release.tagName.first == "v" || release.tagName.first == "V" {
            version = String(release.tagName.dropFirst())
        } else {
            version = release.tagName
        }
        guard CopyClipVersion(version) != nil else {
            throw UpdateFeedError.invalidVersion
        }
        guard let asset = release.assets.first(where: {
            $0.name == Self.releaseAssetName
        }) else {
            throw UpdateFeedError.missingAsset
        }
        try GitHubReleaseURLValidator.validate(asset.downloadURL)
        return CopyClipRelease(version: version, url: asset.downloadURL)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }
}

enum UpdateFeedError: LocalizedError {
    case invalidResponse
    case invalidVersion
    case missingAsset
    case invalidDownloadURL
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The update service returned an invalid response. Try again later."
        case .invalidVersion:
            "The update service returned an invalid version."
        case .missingAsset:
            "The latest release does not include the macOS app download."
        case .invalidDownloadURL:
            "The update service returned an unsafe download address."
        case .unavailable:
            "No public update channel is configured for this build."
        }
    }
}

enum GitHubReleaseURLValidator {
    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil else {
            throw UpdateFeedError.invalidDownloadURL
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, url: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private(set) var checkTask: Task<Void, Never>?

    private let loader: any UpdateFeedLoading
    private let feedURL: URL?
    let currentVersion: String

    convenience init() {
        self.init(
            loader: GitHubUpdateFeedLoader(),
            feedURL: Self.configuredFeedURL,
            currentVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.0.0"
        )
    }

    init(
        loader: any UpdateFeedLoading,
        feedURL: URL?,
        currentVersion: String
    ) {
        self.loader = loader
        self.feedURL = feedURL
        self.currentVersion = currentVersion
    }

    func check() {
        guard state != .checking else { return }
        guard let feedURL else {
            state = .failed(UpdateFeedError.unavailable.localizedDescription)
            return
        }
        guard let installedVersion = CopyClipVersion(currentVersion) else {
            state = .failed("The installed app version is invalid.")
            return
        }

        state = .checking
        checkTask = Task {
            do {
                let release = try await loader.latestRelease(
                    from: feedURL,
                    userAgent: "CopyClipLite/\(currentVersion)"
                )
                guard let latestVersion = CopyClipVersion(release.version) else {
                    throw UpdateFeedError.invalidVersion
                }
                if latestVersion > installedVersion {
                    state = .updateAvailable(version: release.version, url: release.url)
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func openAvailableUpdate() {
        guard case let .updateAvailable(_, url) = state else { return }
        do {
            try GitHubReleaseURLValidator.validate(url)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static var configuredFeedURL: URL? {
        let configured = Bundle.main.object(
            forInfoDictionaryKey: "CopyClipUpdateFeedURL"
        ) as? String
        return configured.flatMap(URL.init(string:))
    }
}
