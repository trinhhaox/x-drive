import Foundation

// MARK: - OrbitDrive (Core Virtual FileSystem Coordinator)

public final class OrbitDrive: @unchecked Sendable {
    public let tree: DriveTree
    public let chunkStore: ChunkStore
    public let contentReader: ContentReader
    public let staging: Staging
    public let xattrStore: XattrStore
    public let remote: DriveRemote
    public let governor: UploadGovernor

    private let lock = NSLock()
    private var openHandles: [UInt64: Int] = [:]
    private var uploadingFiles: [UInt64: UploadingFileInfo] = [:]
    private var failedUploads: [UInt64: FailedUploadInfo] = [:]
    private var recentUploads: [RecentUploadInfo] = []
    private var pausedUploadsCount: Int = 0
    private var politeEnabled: Bool = true

    public init(
        baseDirectory: URL = SharedContainer.driveDirectory,
        remote: DriveRemote,
        governor: UploadGovernor = UploadGovernor()
    ) {
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        self.tree = DriveTree()
        _ = self.tree.load(from: baseDirectory.appendingPathComponent("tree-snapshot.json"))

        let cacheSettings = SharedContainer.readCacheSettings()
        let limits = ChunkStore.Limits(maxBytes: cacheSettings.limitBytes)
        self.chunkStore = ChunkStore(
            baseDirectory: baseDirectory.appendingPathComponent("Chunks", isDirectory: true),
            limits: limits
        )
        self.chunkStore.setPinnedRemoteIDs(SharedContainer.readPinnedRemoteIDs())
        self.contentReader = ContentReader(chunkStore: chunkStore, remote: remote)
        self.staging = Staging(baseDirectory: baseDirectory.appendingPathComponent("Staging", isDirectory: true))
        self.xattrStore = XattrStore(persistenceURL: baseDirectory.appendingPathComponent("xattrs.json"))
        self.remote = remote
        self.governor = governor

        let uploadSettings = SharedContainer.readUploadSettings()
        self.politeEnabled = uploadSettings.polite
        self.governor.setPoliteEnabled(uploadSettings.polite)
    }

    // MARK: - Directory Enumeration & Sync

    public func listDirectory(nodeID: UInt64) async throws -> [DriveNode] {
        if !tree.isPopulated(dirID: nodeID), let dirNode = tree.node(id: nodeID) {
            if nodeID == DriveTree.rootID || dirNode.remoteID != nil {
                let items = try await remote.listDirectory(parentID: dirNode.remoteID)
                tree.populate(dirID: nodeID, remoteItems: items)
                saveTreeSnapshot()
            }
        }
        return tree.listChildren(of: nodeID)
    }

    public func refreshDirectory(nodeID: UInt64) async throws {
        guard let dirNode = tree.node(id: nodeID) else { return }
        let items = try await remote.listDirectory(parentID: dirNode.remoteID)
        tree.populate(dirID: nodeID, remoteItems: items)
        saveTreeSnapshot()
        publishStatus()
    }

    @discardableResult
    public func syncChanges() async throws -> ChangeSummary {
        var cursor = tree.lastChangeSeq
        var combinedContentChanged: [(remoteID: String, newVersion: UInt64)] = []
        var combinedDeleted: [String] = []
        var anyTreeChanged = false

        while true {
            let page = try await remote.changes(since: cursor)
            if !page.changes.isEmpty {
                let summary = tree.applyChanges(page.changes)
                for changed in summary.contentChanged {
                    chunkStore.invalidate(remoteID: changed.remoteID, keepVersion: changed.newVersion)
                    combinedContentChanged.append(changed)
                }
                for delID in summary.deletedRemoteIDs {
                    chunkStore.invalidate(remoteID: delID)
                    combinedDeleted.append(delID)
                }
                if summary.treeChanged { anyTreeChanged = true }
            }
            cursor = page.cursor
            tree.lastChangeSeq = cursor
            if !page.hasMore { break }
        }

        if anyTreeChanged {
            saveTreeSnapshot()
        }
        publishStatus()
        return ChangeSummary(
            contentChanged: combinedContentChanged,
            deletedRemoteIDs: combinedDeleted,
            treeChanged: anyTreeChanged
        )
    }

    // MARK: - POSIX / FSKit File Operations

    public func openFile(nodeID: UInt64) {
        lock.lock()
        openHandles[nodeID, default: 0] += 1
        lock.unlock()
    }

    public func closeFile(nodeID: UInt64) async {
        let shouldFlush: Bool = {
            lock.lock()
            defer { lock.unlock() }
            let count = (openHandles[nodeID] ?? 1) - 1
            if count <= 0 {
                openHandles.removeValue(forKey: nodeID)
                return true
            } else {
                openHandles[nodeID] = count
                return false
            }
        }()

        if shouldFlush, let node = tree.node(id: nodeID), node.dirty {
            await flushStagedNode(nodeID: nodeID)
        }
    }

    public func readFile(nodeID: UInt64, offset: UInt64, length: Int) async throws -> Data {
        guard let node = tree.node(id: nodeID), node.kind == .file else {
            return Data()
        }
        if staging.hasStagedFile(nodeID: nodeID) {
            return try staging.read(nodeID: nodeID, offset: offset, length: length)
        }
        guard let remoteID = node.remoteID else {
            return Data()
        }
        return try await contentReader.read(
            remoteID: remoteID,
            version: node.contentVersion,
            fileSize: node.size,
            offset: offset,
            length: length
        )
    }

    public func writeFile(nodeID: UInt64, data: Data, offset: UInt64) async throws -> Int {
        guard let node = tree.node(id: nodeID), node.kind == .file else {
            return 0
        }
        // Copy remote content into staging on first partial overwrite if needed
        if !staging.hasStagedFile(nodeID: nodeID), let remoteID = node.remoteID, node.size > 0, (offset > 0 || data.count < Int(node.size)) {
            let existing = try await contentReader.read(
                remoteID: remoteID,
                version: node.contentVersion,
                fileSize: node.size,
                offset: 0,
                length: Int(node.size)
            )
            try staging.ensureStagedFile(nodeID: nodeID, initialData: existing)
        }
        let newSize = try staging.write(nodeID: nodeID, data: data, offset: offset)
        tree.updateSize(id: nodeID, size: newSize, markDirty: true)
        saveTreeSnapshot()
        publishStatus()
        return data.count
    }

    public func createItem(name: String, parentID: UInt64, kind: NodeKind, symlinkTarget: String? = nil) async throws -> DriveNode {
        let local = tree.createLocal(name: name, parentID: parentID, kind: kind, symlinkTarget: symlinkTarget)
        if kind == .file {
            try staging.ensureStagedFile(nodeID: local.id)
        } else if kind == .directory {
            let parentRemoteID = tree.node(id: parentID)?.remoteID
            if let remoteFolder = try? await remote.createDirectory(name: name, parentID: parentRemoteID) {
                tree.markSynced(id: local.id, remoteID: remoteFolder.id, clearDirty: true)
            }
        }
        saveTreeSnapshot()
        publishStatus()
        return tree.node(id: local.id) ?? local
    }

    public func removeItem(nodeID: UInt64) async throws {
        guard let removed = tree.remove(id: nodeID) else { return }
        staging.discard(nodeID: nodeID)
        xattrStore.removeAll(nodeID: nodeID)
        if let remID = removed.remoteID {
            chunkStore.invalidate(remoteID: remID)
        }
        for pending in tree.drainPendingDeletes() {
            try? await remote.delete(id: pending.remoteID)
        }
        saveTreeSnapshot()
        publishStatus()
    }

    public func renameItem(nodeID: UInt64, newParentID: UInt64, newName: String) async throws -> DriveNode? {
        guard let oldNode = tree.node(id: nodeID) else { return nil }
        guard let updated = tree.rename(id: nodeID, newParentID: newParentID, newName: newName) else { return nil }

        if let remID = updated.remoteID {
            let newParentRemoteID = tree.node(id: newParentID)?.remoteID
            if oldNode.parentID != newParentID {
                _ = try? await remote.move(id: remID, newParentID: newParentRemoteID, currentName: newName)
            }
            if oldNode.name != newName {
                _ = try? await remote.rename(id: remID, newName: newName, parentID: newParentRemoteID)
            }
        }
        saveTreeSnapshot()
        publishStatus()
        return updated
    }

    // MARK: - Background Upload Flushing (Small & Big Lanes)

    public func flushStagedNode(nodeID: UInt64) async {
        guard let node = tree.node(id: nodeID), node.kind == .file else { return }
        let stagedURL = staging.fileURL(for: nodeID)
        guard FileManager.default.fileExists(atPath: stagedURL.path) else { return }

        let parentRemoteID = tree.node(id: node.parentID)?.remoteID
        let relPath = tree.relativePath(of: nodeID)

        lock.withLock {
            uploadingFiles[nodeID] = UploadingFileInfo(
                id: nodeID,
                name: node.name,
                size: node.size,
                bytesSent: 0,
                startedAt: Date(),
                relativePath: relPath
            )
            failedUploads.removeValue(forKey: nodeID)
        }
        publishStatus()

        do {
            let source = try FileBlobSource(fileURL: stagedURL)
            let result = try await remote.uploadFile(
                existingRemoteID: node.remoteID,
                name: node.name,
                parentID: parentRemoteID,
                source: source,
                createdAt: node.createdAt,
                modifiedAt: node.modifiedAt,
                onProgress: { [weak self] bytesSent in
                    guard let self else { return }
                    self.lock.withLock {
                        self.uploadingFiles[nodeID]?.bytesSent = min(node.size, bytesSent)
                    }
                    self.publishStatus()
                }
            )

            tree.markSynced(id: nodeID, remoteID: result.id, clearDirty: true)
            let syncedVersion = tree.node(id: nodeID)?.contentVersion ?? 1
            chunkStore.seedFromFile(url: stagedURL, remoteID: result.id, version: syncedVersion)
            staging.discard(nodeID: nodeID)

            lock.withLock {
                _ = uploadingFiles.removeValue(forKey: nodeID)
                recentUploads.insert(
                    RecentUploadInfo(name: node.name, size: node.size, finishedAt: Date(), relativePath: relPath),
                    at: 0
                )
                if recentUploads.count > 20 {
                    recentUploads = Array(recentUploads.prefix(20))
                }
            }

            saveTreeSnapshot()
            publishStatus()
        } catch {
            lock.withLock {
                _ = uploadingFiles.removeValue(forKey: nodeID)
                failedUploads[nodeID] = FailedUploadInfo(
                    id: nodeID,
                    name: node.name,
                    size: node.size,
                    failedAt: Date(),
                    reason: error.localizedDescription,
                    relativePath: relPath
                )
            }
            publishStatus()
        }
    }

    // MARK: - Snapshot & Status Publishing

    public func saveTreeSnapshot() {
        try? tree.save(to: SharedContainer.treeFile)
    }

    public func currentStatusSnapshot() -> DriveStatusSnapshot {
        let dirtyCount = tree.dirtyNodes().count
        let pinnedIDs = Array(SharedContainer.readPinnedRemoteIDs()).sorted()
        lock.lock()
        let uploading = Array(uploadingFiles.values).sorted { $0.startedAt < $1.startedAt }
        let failed = Array(failedUploads.values).sorted { $0.failedAt > $1.failedAt }
        let recent = recentUploads
        let paused = pausedUploadsCount
        let polite = politeEnabled
        lock.unlock()

        return DriveStatusSnapshot(
            updatedAt: Date(),
            pendingCount: dirtyCount,
            uploadingFiles: uploading,
            failedUploads: failed,
            recentUploads: recent,
            cacheBytes: chunkStore.totalBytes,
            pinnedBytes: chunkStore.pinnedBytes,
            pinnedRemoteIDs: pinnedIDs,
            cachedRemoteIDs: chunkStore.cachedRemoteIDs(),
            uploadBytesPerSec: governor.currentThroughputBytesPerSec(),
            pausedUploadsCount: paused,
            politeUploads: polite,
            throttling: governor.isThrottling
        )
    }

    public func publishStatus() {
        SharedContainer.writeDriveStatus(currentStatusSnapshot())
    }
}

// MARK: - LocalWireRemote (In-Memory / Disk Cloud Simulator for Local Execution & Testing)

public final class LocalWireRemote: WireRemote, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: FileItem] = [:]
    private var blobs: [String: Data] = [:]
    private var changeLog: [ChangeEntry] = []
    private var nextSeq: Int64 = 1

    public init() {}

    public func listDirectory(parentID: String?) async throws -> [FileItem] {
        lock.withLock {
            items.values.filter { $0.parentID == parentID }.sorted { $0.name < $1.name }
        }
    }

    public func allFiles() async throws -> [FileItem] {
        lock.withLock {
            Array(items.values)
        }
    }

    public func changes(since cursor: Int64) async throws -> ChangePage {
        lock.withLock {
            let filtered = changeLog.filter { $0.seq > cursor }
            let maxSeq = changeLog.last?.seq ?? cursor
            return ChangePage(changes: filtered, cursor: maxSeq, hasMore: false)
        }
    }

    public func getItem(id: String) async throws -> FileItem {
        try lock.withLock {
            guard let item = items[id] else { throw OrbitAPIError.notFound(id) }
            return item
        }
    }

    public func createDirectory(name: String, parentID: String?) async throws -> FileItem {
        try await createDirectoryWire(name: name, parentID: parentID, wire: nil)
    }

    public func createDirectoryWire(name: String, parentID: String?, wire: ZK.WireName?) async throws -> FileItem {
        lock.withLock {
            let id = "dir_\(UUID().uuidString.lowercased())"
            let now = Date()
            let item = FileItem(
                id: id,
                name: name,
                parentID: parentID,
                isDirectory: true,
                size: 0,
                createdAt: now,
                updatedAt: now,
                encName: wire?.encName
            )
            items[id] = item
            recordChangeLocked(item: item, action: "upsert")
            return item
        }
    }

    public func rename(id: String, newName: String, parentID: String?) async throws -> FileItem {
        try await renameWire(id: id, newName: newName, wire: nil)
    }

    public func renameWire(id: String, newName: String, wire: ZK.WireName?) async throws -> FileItem {
        try lock.withLock {
            guard var item = items[id] else { throw OrbitAPIError.notFound(id) }
            item.name = newName
            if let wire { item.encName = wire.encName }
            item.updatedAt = Date()
            items[id] = item
            recordChangeLocked(item: item, action: "upsert")
            return item
        }
    }

    public func move(id: String, newParentID: String?, currentName: String) async throws -> FileItem {
        try await moveWire(id: id, newParentID: newParentID, wire: nil)
    }

    public func moveWire(id: String, newParentID: String?, wire: ZK.WireName?) async throws -> FileItem {
        try lock.withLock {
            guard var item = items[id] else { throw OrbitAPIError.notFound(id) }
            item.parentID = newParentID
            if let wire { item.encName = wire.encName }
            item.updatedAt = Date()
            items[id] = item
            recordChangeLocked(item: item, action: "upsert")
            return item
        }
    }

    public func delete(id: String) async throws {
        lock.withLock {
            _ = items.removeValue(forKey: id)
            _ = blobs.removeValue(forKey: id)
            let seq = nextSeq
            nextSeq += 1
            changeLog.append(ChangeEntry(seq: seq, fileID: id, action: "delete"))
        }
    }

    public func updateTimestamps(id: String, createdAt: Date?, modifiedAt: Date?) async throws {
        lock.withLock {
            guard var item = items[id] else { return }
            if let createdAt { item.createdAt = createdAt }
            if let modifiedAt { item.updatedAt = modifiedAt }
            items[id] = item
        }
    }

    public func fetchRange(remoteID: String, range: Range<UInt64>) async throws -> Data {
        let data: Data = try lock.withLock {
            guard let found = blobs[remoteID] else {
                throw OrbitAPIError.notFound(remoteID)
            }
            return found
        }
        let start = Int(min(UInt64(data.count), range.lowerBound))
        let end = Int(min(UInt64(data.count), range.upperBound))
        guard start < end else { return Data() }
        return data.subdata(in: start..<end)
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
        try await uploadFileWire(
            existingRemoteID: existingRemoteID,
            name: name,
            parentID: parentID,
            source: source,
            wire: nil,
            secrets: nil,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            onProgress: onProgress
        )
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
        let data = try source.readSlice(offset: 0, length: Int(source.totalSize))
        onProgress?(UInt64(data.count))

        return lock.withLock {
            let id = existingRemoteID ?? "file_\(UUID().uuidString.lowercased())"
            let now = Date()
            let item = FileItem(
                id: id,
                name: name,
                parentID: parentID,
                isDirectory: false,
                size: Int64(data.count),
                createdAt: createdAt ?? now,
                updatedAt: modifiedAt ?? now,
                encName: wire?.encName,
                fileKey: secrets?.fileKey,
                fileNonce: secrets?.fileNonce,
                plainSize: secrets?.plainSize
            )
            items[id] = item
            blobs[id] = data
            recordChangeLocked(item: item, action: "upsert")
            return UploadResult(id: id, name: name, size: item.size, parentID: parentID, updatedAt: item.updatedAt)
        }
    }

    public func unsealedFiles() async throws -> [UnsealedFile] {
        lock.withLock {
            items.values
                .filter { $0.encName == nil }
                .map { UnsealedFile(id: $0.id, name: $0.name, parentID: $0.parentID, isDirectory: $0.isDirectory, size: $0.size) }
        }
    }

    public func lockFileBatch(_ entries: [LockedFileEntry]) async throws {
        lock.withLock {
            for entry in entries {
                guard var item = items[entry.id] else { continue }
                item.encName = entry.encName
                if let fk = entry.fileKey { item.fileKey = fk }
                if let fn = entry.fileNonce { item.fileNonce = fn }
                if let ps = entry.plainSize { item.plainSize = ps }
                items[entry.id] = item
                recordChangeLocked(item: item, action: "upsert")
            }
        }
    }

    public func putEncryptedFileContent(id: String, source: BlobSource, secrets: ZK.WireSecrets) async throws {
        let cipher = try source.readSlice(offset: 0, length: Int(source.totalSize))
        lock.withLock {
            blobs[id] = cipher
            if var item = items[id] {
                item.size = Int64(cipher.count)
                item.fileKey = secrets.fileKey
                item.fileNonce = secrets.fileNonce
                item.plainSize = secrets.plainSize
                items[id] = item
            }
        }
    }

    private func recordChangeLocked(item: FileItem, action: String) {
        let seq = nextSeq
        nextSeq += 1
        changeLog.append(
            ChangeEntry(
                seq: seq,
                fileID: item.id,
                action: action,
                name: item.name,
                parentID: item.parentID,
                isDirectory: item.isDirectory,
                size: item.size,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                encName: item.encName,
                fileKey: item.fileKey,
                fileNonce: item.fileNonce,
                plainSize: item.plainSize,
                sealPublic: item.sealPublic
            )
        )
    }
}
