import Foundation
import CryptoKit

// MARK: - Core File & Tree Models

public enum NodeKind: String, Codable, Sendable {
    case file
    case directory
    case symlink
}

public struct DriveNode: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt64
    public var remoteID: String?
    public var parentID: UInt64
    public var name: String
    public var kind: NodeKind
    public var size: UInt64
    public var createdAt: Date
    public var modifiedAt: Date
    public var dirty: Bool
    public var contentVersion: UInt64
    public var symlinkTarget: String?
    public var metadataPending: Bool
    public var isLink: Bool

    public init(
        id: UInt64,
        remoteID: String? = nil,
        parentID: UInt64,
        name: String,
        kind: NodeKind,
        size: UInt64 = 0,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        dirty: Bool = false,
        contentVersion: UInt64 = 1,
        symlinkTarget: String? = nil,
        metadataPending: Bool = false,
        isLink: Bool = false
    ) {
        self.id = id
        self.remoteID = remoteID
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.size = size
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.dirty = dirty
        self.contentVersion = contentVersion
        self.symlinkTarget = symlinkTarget
        self.metadataPending = metadataPending
        self.isLink = isLink
    }
}

// MARK: - Remote API & Sync Models

public struct FileItem: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var isDirectory: Bool
    public var size: Int64
    public var mimeType: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var encName: String?
    public var fileKey: String?
    public var fileNonce: String?
    public var plainSize: Int64?
    public var sealPublic: String?

    public init(
        id: String,
        name: String,
        parentID: String? = nil,
        isDirectory: Bool,
        size: Int64 = 0,
        mimeType: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        encName: String? = nil,
        fileKey: String? = nil,
        fileNonce: String? = nil,
        plainSize: Int64? = nil,
        sealPublic: String? = nil
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.isDirectory = isDirectory
        self.size = size
        self.mimeType = mimeType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.encName = encName
        self.fileKey = fileKey
        self.fileNonce = fileNonce
        self.plainSize = plainSize
        self.sealPublic = sealPublic
    }
}

public struct ChangeEntry: Codable, Equatable, Sendable {
    public var seq: Int64
    public var fileID: String
    public var action: String // "upsert" | "delete"
    public var name: String?
    public var parentID: String?
    public var isDirectory: Bool?
    public var size: Int64?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var encName: String?
    public var fileKey: String?
    public var fileNonce: String?
    public var plainSize: Int64?
    public var sealPublic: String?

    public init(
        seq: Int64,
        fileID: String,
        action: String,
        name: String? = nil,
        parentID: String? = nil,
        isDirectory: Bool? = nil,
        size: Int64? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        encName: String? = nil,
        fileKey: String? = nil,
        fileNonce: String? = nil,
        plainSize: Int64? = nil,
        sealPublic: String? = nil
    ) {
        self.seq = seq
        self.fileID = fileID
        self.action = action
        self.name = name
        self.parentID = parentID
        self.isDirectory = isDirectory
        self.size = size
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.encName = encName
        self.fileKey = fileKey
        self.fileNonce = fileNonce
        self.plainSize = plainSize
        self.sealPublic = sealPublic
    }
}

public struct ChangePage: Codable, Equatable, Sendable {
    public var changes: [ChangeEntry]
    public var cursor: Int64
    public var hasMore: Bool

    public init(changes: [ChangeEntry], cursor: Int64, hasMore: Bool) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

public struct ChangeSummary: Equatable, Sendable {
    public var contentChanged: [(remoteID: String, newVersion: UInt64)]
    public var deletedRemoteIDs: [String]
    public var treeChanged: Bool

    public init(
        contentChanged: [(remoteID: String, newVersion: UInt64)] = [],
        deletedRemoteIDs: [String] = [],
        treeChanged: Bool = false
    ) {
        self.contentChanged = contentChanged
        self.deletedRemoteIDs = deletedRemoteIDs
        self.treeChanged = treeChanged
    }

    public static func == (lhs: ChangeSummary, rhs: ChangeSummary) -> Bool {
        guard lhs.deletedRemoteIDs == rhs.deletedRemoteIDs,
              lhs.treeChanged == rhs.treeChanged,
              lhs.contentChanged.count == rhs.contentChanged.count else {
            return false
        }
        for (l, r) in zip(lhs.contentChanged, rhs.contentChanged) {
            if l.remoteID != r.remoteID || l.newVersion != r.newVersion {
                return false
            }
        }
        return true
    }
}

public struct QuotaInfo: Codable, Equatable, Sendable {
    public var usedBytes: Int64
    public var limitBytes: Int64
    public var plan: String
    public var fileCount: Int

    public init(usedBytes: Int64, limitBytes: Int64, plan: String, fileCount: Int) {
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
        self.plan = plan
        self.fileCount = fileCount
    }
}

public struct UserInfo: Codable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var name: String?
    public var plan: String
    public var storageUsed: Int64
    public var storageLimit: Int64

    public init(id: String, email: String, name: String?, plan: String, storageUsed: Int64, storageLimit: Int64) {
        self.id = id
        self.email = email
        self.name = name
        self.plan = plan
        self.storageUsed = storageUsed
        self.storageLimit = storageLimit
    }
}

public struct SessionResponse: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresIn: Int
    public var user: UserInfo

    public init(accessToken: String, refreshToken: String, expiresIn: Int, user: UserInfo) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.user = user
    }
}

public struct ContentURL: Codable, Equatable, Sendable {
    public var url: URL
    public var expiresIn: Int

    public init(url: URL, expiresIn: Int) {
        self.url = url
        self.expiresIn = expiresIn
    }
}

public struct UploadResult: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var size: Int64
    public var parentID: String?
    public var updatedAt: Date?

    public init(id: String, name: String, size: Int64, parentID: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.parentID = parentID
        self.updatedAt = updatedAt
    }
}

public struct MultipartPartSpec: Codable, Equatable, Sendable {
    public var partNumber: Int
    public var url: URL

    public init(partNumber: Int, url: URL) {
        self.partNumber = partNumber
        self.url = url
    }
}

public struct MultipartUploadSession: Codable, Equatable, Sendable {
    public var fileID: String
    public var uploadID: String
    public var partSize: Int
    public var parts: [MultipartPartSpec]
    public var totalParts: Int?
    public var concurrency: Int?
    public var presignBatch: Int?

    public init(
        fileID: String,
        uploadID: String,
        partSize: Int,
        parts: [MultipartPartSpec],
        totalParts: Int? = nil,
        concurrency: Int? = 4,
        presignBatch: Int? = 16
    ) {
        self.fileID = fileID
        self.uploadID = uploadID
        self.partSize = partSize
        self.parts = parts
        self.totalParts = totalParts
        self.concurrency = concurrency
        self.presignBatch = presignBatch
    }
}

public struct CompletedPart: Codable, Equatable, Sendable {
    public var partNumber: Int
    public var etag: String

    public init(partNumber: Int, etag: String) {
        self.partNumber = partNumber
        self.etag = etag
    }
}

public struct FileRequestInfo: Codable, Equatable, Sendable {
    public var token: String
    public var url: URL
    public var folderID: String
    public var folderName: String
    public var createdAt: Date

    public init(token: String, url: URL, folderID: String, folderName: String, createdAt: Date = Date()) {
        self.token = token
        self.url = url
        self.folderID = folderID
        self.folderName = folderName
        self.createdAt = createdAt
    }
}

public struct ShareLinkItem: Codable, Equatable, Identifiable, Sendable {
    public var token: String
    public var url: URL
    public var fileID: String
    public var fileName: String
    public var isDirectory: Bool
    public var size: Int64
    public var createdAt: Date
    public var expiresAt: Date?
    public var downloads: Int
    public var shareKeyWrap: String?

    public var id: String { token }

    public init(
        token: String,
        url: URL,
        fileID: String,
        fileName: String,
        isDirectory: Bool,
        size: Int64,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        downloads: Int = 0,
        shareKeyWrap: String? = nil
    ) {
        self.token = token
        self.url = url
        self.fileID = fileID
        self.fileName = fileName
        self.isDirectory = isDirectory
        self.size = size
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.downloads = downloads
        self.shareKeyWrap = shareKeyWrap
    }
}

// MARK: - Drive Status & Settings Models

public struct UploadingFileInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt64
    public var name: String
    public var size: UInt64
    public var bytesSent: UInt64
    public var startedAt: Date
    public var relativePath: String?

    public init(id: UInt64, name: String, size: UInt64, bytesSent: UInt64 = 0, startedAt: Date = Date(), relativePath: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.bytesSent = bytesSent
        self.startedAt = startedAt
        self.relativePath = relativePath
    }
}

public struct FailedUploadInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt64
    public var name: String
    public var size: UInt64
    public var failedAt: Date
    public var reason: String
    public var relativePath: String?

    public init(id: UInt64, name: String, size: UInt64, failedAt: Date = Date(), reason: String, relativePath: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.failedAt = failedAt
        self.reason = reason
        self.relativePath = relativePath
    }
}

public struct RecentUploadInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(name)-\(finishedAt.timeIntervalSince1970)" }
    public var name: String
    public var size: UInt64
    public var finishedAt: Date
    public var relativePath: String?

    public init(name: String, size: UInt64, finishedAt: Date = Date(), relativePath: String? = nil) {
        self.name = name
        self.size = size
        self.finishedAt = finishedAt
        self.relativePath = relativePath
    }
}

public struct DriveStatusSnapshot: Codable, Equatable, Sendable {
    public var updatedAt: Date
    public var pendingCount: Int
    public var uploadingFiles: [UploadingFileInfo]
    public var failedUploads: [FailedUploadInfo]
    public var recentUploads: [RecentUploadInfo]
    public var cacheBytes: UInt64
    public var pinnedBytes: UInt64
    public var pinnedRemoteIDs: [String]
    public var cachedRemoteIDs: [String]
    public var uploadBytesPerSec: UInt64
    public var pausedUploadsCount: Int
    public var politeUploads: Bool
    public var throttling: Bool

    public init(
        updatedAt: Date = Date(),
        pendingCount: Int = 0,
        uploadingFiles: [UploadingFileInfo] = [],
        failedUploads: [FailedUploadInfo] = [],
        recentUploads: [RecentUploadInfo] = [],
        cacheBytes: UInt64 = 0,
        pinnedBytes: UInt64 = 0,
        pinnedRemoteIDs: [String] = [],
        cachedRemoteIDs: [String] = [],
        uploadBytesPerSec: UInt64 = 0,
        pausedUploadsCount: Int = 0,
        politeUploads: Bool = true,
        throttling: Bool = false
    ) {
        self.updatedAt = updatedAt
        self.pendingCount = pendingCount
        self.uploadingFiles = uploadingFiles
        self.failedUploads = failedUploads
        self.recentUploads = recentUploads
        self.cacheBytes = cacheBytes
        self.pinnedBytes = pinnedBytes
        self.pinnedRemoteIDs = pinnedRemoteIDs
        self.cachedRemoteIDs = cachedRemoteIDs
        self.uploadBytesPerSec = uploadBytesPerSec
        self.pausedUploadsCount = pausedUploadsCount
        self.politeUploads = politeUploads
        self.throttling = throttling
    }
}

public struct CacheSettings: Codable, Equatable, Sendable {
    public var limitBytes: UInt64

    public init(limitBytes: UInt64 = 10 * 1024 * 1024 * 1024) { // Default 10 GiB
        self.limitBytes = limitBytes
    }
}

public struct UploadSettings: Codable, Equatable, Sendable {
    public var polite: Bool

    public init(polite: Bool = true) {
        self.polite = polite
    }
}

// MARK: - Zero-Knowledge Privacy & Device Approval Models

public struct SweepProgress: Codable, Equatable, Sendable {
    public var total: Int
    public var done: Int

    public init(total: Int, done: Int) {
        self.total = total
        self.done = done
    }
}

public enum PrivacyState: Equatable, Sendable {
    case off
    case locked
    case unlocked(ZK.AccountKeys)
    case migrating(SweepProgress)
}

public struct PrivacyStatusResponse: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var keyCheck: String?
    public var dropPublic: String?
    public var dropPrivateWrap: String?
    public var unsealedCount: Int

    public init(
        enabled: Bool,
        keyCheck: String? = nil,
        dropPublic: String? = nil,
        dropPrivateWrap: String? = nil,
        unsealedCount: Int = 0
    ) {
        self.enabled = enabled
        self.keyCheck = keyCheck
        self.dropPublic = dropPublic
        self.dropPrivateWrap = dropPrivateWrap
        self.unsealedCount = unsealedCount
    }
}

public struct UnsealedFile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var parentID: String?
    public var isDirectory: Bool
    public var size: Int64

    public init(id: String, name: String, parentID: String?, isDirectory: Bool, size: Int64) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct LockedFileEntry: Codable, Equatable, Sendable {
    public var id: String
    public var encName: String
    public var nameHash: String
    public var fileKey: String?
    public var fileNonce: String?
    public var plainSize: Int64?

    public init(
        id: String,
        encName: String,
        nameHash: String,
        fileKey: String? = nil,
        fileNonce: String? = nil,
        plainSize: Int64? = nil
    ) {
        self.id = id
        self.encName = encName
        self.nameHash = nameHash
        self.fileKey = fileKey
        self.fileNonce = fileNonce
        self.plainSize = plainSize
    }
}

public struct FileRewrapEntry: Codable, Equatable, Sendable {
    public var id: String
    public var encName: String
    public var nameHash: String
    public var fileKey: String
    public var fileNonce: String
    public var plainSize: Int64

    public init(id: String, encName: String, nameHash: String, fileKey: String, fileNonce: String, plainSize: Int64) {
        self.id = id
        self.encName = encName
        self.nameHash = nameHash
        self.fileKey = fileKey
        self.fileNonce = fileNonce
        self.plainSize = plainSize
    }
}

public struct ShareRewrapEntry: Codable, Equatable, Sendable {
    public var token: String
    public var fileKey: String
    public var fileNonce: String
    public var encName: String
    public var shareKeyWrap: String

    public init(token: String, fileKey: String, fileNonce: String, encName: String, shareKeyWrap: String) {
        self.token = token
        self.fileKey = fileKey
        self.fileNonce = fileNonce
        self.encName = encName
        self.shareKeyWrap = shareKeyWrap
    }
}

public struct DeviceApprovalRequest: Codable, Equatable, Sendable {
    public var id: String
    public var expiresAt: Int64

    public init(id: String, expiresAt: Int64) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

public struct DeviceApprovalPollResponse: Codable, Equatable, Sendable {
    public var status: String // "pending" | "approved" | "rejected"
    public var grant: String?

    public init(status: String, grant: String? = nil) {
        self.status = status
        self.grant = grant
    }
}

public struct PendingDeviceApproval: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var deviceName: String
    public var publicKey: String
    public var createdAt: Int64
    public var expiresAt: Int64

    public init(id: String, deviceName: String, publicKey: String, createdAt: Int64, expiresAt: Int64) {
        self.id = id
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

