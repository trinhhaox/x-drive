import Foundation

// MARK: - MultiCloudProviderType

public enum MultiCloudProviderType: String, CaseIterable, Identifiable, Sendable {
    case cloudflare = "Cloudflare D1 & R2 (OrbitAPI)"
    case googleDrive = "Google Drive (Google API v3)"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .cloudflare: return "cloud.fill"
        case .googleDrive: return "externaldrive.fill.badge.icloud"
        }
    }
}

// MARK: - MultiCloudProxyRemote (Dynamic Multi-Cloud Storage Switcher)

public final class MultiCloudProxyRemote: WireRemote, @unchecked Sendable {
    private let lock = NSLock()
    private var providerType: MultiCloudProviderType
    private var activeBackend: WireRemote

    public let cloudflareBackend: OrbitAPI
    public let googleDriveBackend: GoogleDriveRemote

    public init(
        initialProvider: MultiCloudProviderType = .cloudflare,
        cloudflareBackend: OrbitAPI = OrbitAPI(),
        googleDriveBackend: GoogleDriveRemote = GoogleDriveRemote()
    ) {
        self.providerType = initialProvider
        self.cloudflareBackend = cloudflareBackend
        self.googleDriveBackend = googleDriveBackend

        switch initialProvider {
        case .cloudflare:
            self.activeBackend = cloudflareBackend
        case .googleDrive:
            self.activeBackend = googleDriveBackend
        }
    }

    public func setProvider(_ newType: MultiCloudProviderType) {
        lock.withLock {
            self.providerType = newType
            switch newType {
            case .cloudflare:
                self.activeBackend = cloudflareBackend
            case .googleDrive:
                self.activeBackend = googleDriveBackend
            }
        }
    }

    public var currentProvider: MultiCloudProviderType {
        lock.withLock { providerType }
    }

    private var backend: WireRemote {
        lock.withLock { activeBackend }
    }

    // MARK: - DriveRemote Forwarding

    public func listDirectory(parentID: String?) async throws -> [FileItem] {
        try await backend.listDirectory(parentID: parentID)
    }

    public func allFiles() async throws -> [FileItem] {
        try await backend.allFiles()
    }

    public func changes(since cursor: Int64) async throws -> ChangePage {
        try await backend.changes(since: cursor)
    }

    public func getItem(id: String) async throws -> FileItem {
        try await backend.getItem(id: id)
    }

    public func createDirectory(name: String, parentID: String?) async throws -> FileItem {
        try await backend.createDirectory(name: name, parentID: parentID)
    }

    public func rename(id: String, newName: String, parentID: String?) async throws -> FileItem {
        try await backend.rename(id: id, newName: newName, parentID: parentID)
    }

    public func move(id: String, newParentID: String?, currentName: String) async throws -> FileItem {
        try await backend.move(id: id, newParentID: newParentID, currentName: currentName)
    }

    public func delete(id: String) async throws {
        try await backend.delete(id: id)
    }

    public func updateTimestamps(id: String, createdAt: Date?, modifiedAt: Date?) async throws {
        try await backend.updateTimestamps(id: id, createdAt: createdAt, modifiedAt: modifiedAt)
    }

    public func fetchRange(remoteID: String, range: Range<UInt64>) async throws -> Data {
        try await backend.fetchRange(remoteID: remoteID, range: range)
    }

    public func uploadFile(
        existingRemoteID: String?,
        name: String,
        parentID: String?,
        source: BlobSource,
        createdAt: Date?,
        modifiedAt: Date?,
        onProgress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UploadResult {
        try await backend.uploadFile(
            existingRemoteID: existingRemoteID,
            name: name,
            parentID: parentID,
            source: source,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            onProgress: onProgress
        )
    }

    // MARK: - WireRemote Forwarding

    public func createDirectoryWire(name: String, parentID: String?, wire: ZK.WireName?) async throws -> FileItem {
        try await backend.createDirectoryWire(name: name, parentID: parentID, wire: wire)
    }

    public func renameWire(id: String, newName: String, wire: ZK.WireName?) async throws -> FileItem {
        try await backend.renameWire(id: id, newName: newName, wire: wire)
    }

    public func moveWire(id: String, newParentID: String?, wire: ZK.WireName?) async throws -> FileItem {
        try await backend.moveWire(id: id, newParentID: newParentID, wire: wire)
    }

    public func uploadFileWire(
        existingRemoteID: String?,
        name: String,
        parentID: String?,
        source: BlobSource,
        wire: ZK.WireName?,
        secrets: ZK.WireSecrets?,
        createdAt: Date?,
        modifiedAt: Date?,
        onProgress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UploadResult {
        try await backend.uploadFileWire(
            existingRemoteID: existingRemoteID,
            name: name,
            parentID: parentID,
            source: source,
            wire: wire,
            secrets: secrets,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            onProgress: onProgress
        )
    }

    public func unsealedFiles() async throws -> [UnsealedFile] {
        try await backend.unsealedFiles()
    }

    public func lockFileBatch(_ entries: [LockedFileEntry]) async throws {
        try await backend.lockFileBatch(entries)
    }

    public func putEncryptedFileContent(id: String, source: BlobSource, secrets: ZK.WireSecrets) async throws {
        try await backend.putEncryptedFileContent(id: id, source: source, secrets: secrets)
    }
}

