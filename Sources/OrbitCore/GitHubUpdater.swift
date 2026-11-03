import CryptoKit
import Foundation

// MARK: - GitHub Release Models & Version Comparator

public struct GitHubReleaseAsset: Codable, Equatable, Sendable {
    public let name: String
    public let browserDownloadURL: URL
    public let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }

    public init(name: String, browserDownloadURL: URL, size: Int64) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
    }
}

public struct GitHubReleaseInfo: Codable, Equatable, Sendable {
    public let tagName: String
    public let name: String
    public let body: String
    public let htmlURL: URL
    public let prerelease: Bool
    public let draft: Bool
    public let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case prerelease
        case draft
        case assets
    }

    public init(
        tagName: String,
        name: String,
        body: String,
        htmlURL: URL,
        prerelease: Bool = false,
        draft: Bool = false,
        assets: [GitHubReleaseAsset]
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.prerelease = prerelease
        self.draft = draft
        self.assets = assets
    }

    /// Clean version string without leading `v` or `V` (e.g. `"v0.3.14"` -> `"0.3.14"`).
    public var cleanVersion: String {
        var s = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        return s
    }

    /// Picks the preferred `.zip` bundle asset for in-place update, falling back to `.dmg`.
    public var preferredAppArchiveAsset: GitHubReleaseAsset? {
        if let zip = assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) {
            return zip
        }
        return assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
    }

    /// Finds `SHA256SUMS.txt` asset if published in the release.
    public var sha256SumsAsset: GitHubReleaseAsset? {
        assets.first(where: { $0.name.uppercased() == "SHA256SUMS.TXT" })
    }
}

public enum GitHubUpdateVerifier {
    /// Returns `true` if `candidate` semantic version is strictly greater than `current`.
    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = parseVersionComponents(candidate)
        let rhs = parseVersionComponents(current)
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r {
                return l > r
            }
        }
        return false
    }

    public static func parseVersionComponents(_ raw: String) -> [Int] {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        // Strip any build metadata suffix like "-beta1"
        if let dashIndex = cleaned.firstIndex(of: "-") {
            cleaned = String(cleaned[..<dashIndex])
        }
        return cleaned.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Parses a `SHA256SUMS.txt` file and returns the expected lowercase hex SHA-256 digest for `assetName`.
    public static func expectedSHA256(for assetName: String, in sha256SumsContent: String) -> String? {
        for line in sha256SumsContent.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2 {
                let hash = String(parts[0]).lowercased()
                let file = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                if file == assetName {
                    return hash
                }
            }
        }
        return nil
    }

    /// Computes lowercase hex SHA-256 of `data`.
    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

