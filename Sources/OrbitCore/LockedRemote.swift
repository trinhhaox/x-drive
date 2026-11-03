import Foundation

// MARK: - WireRemote Protocol (Extended Backend Supporting Wire Names & Secrets)

public protocol WireRemote: DriveRemote {
    func createDirectoryWire(name: String, parentID: String?, wire: ZK.WireName?) async throws -> FileItem
    func renameWire(id: String, newName: String, wire: ZK.WireName?) async throws -> FileItem
    func moveWire(id: String, newParentID: String?, wire: ZK.WireName?) async throws -> FileItem
    func uploadFileWire(
        existingRemoteID: String?,
        name: String,
        parentID: String?,
        source: BlobSource,
        wire: ZK.WireName?,
        secrets: ZK.WireSecrets?,
        createdAt: Date?,
        modifiedAt: Date?,
        onProgress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UploadResult
    func unsealedFiles() async throws -> [UnsealedFile]
    func lockFileBatch(_ entries: [LockedFileEntry]) async throws
    func putEncryptedFileContent(id: String, source: BlobSource, secrets: ZK.WireSecrets) async throws
}

// MARK: - LockedRemote (Transparent Zero-Knowledge E2EE Decorator)

public final class LockedRemote: DriveRemote, @unchecked Sendable {
    private let inner: WireRemote
    public let keyManager: KeyManager
    private let lock = NSLock()
    private var secretsByID: [String: (secrets: ZK.FileSecrets, plainSize: UInt64)] = [:]

    public init(inner: WireRemote, keyManager: KeyManager) {
        self.inner = inner
        self.keyManager = keyManager
    }

    // MARK: - Item Decryption & Secrets Caching

    private func decryptItem(_ item: FileItem) -> FileItem {
        guard let keys = keyManager.keys else { return item }
        var out = item
        if let enc = item.encName, let unlockedName = try? ZK.unlockName(enc, keys: keys) {
            out.name = unlockedName
        }
        if let fk = item.fileKey, let fn = item.fileNonce {
            let wire = ZK.WireSecrets(fileKey: fk, fileNonce: fn, plainSize: item.plainSize ?? item.size)
            if let (sec, plainSz) = try? ZK.unwrapFileSecrets(wire, with: keys) {
                lock.lock()
                secretsByID[item.id] = (sec, plainSz)
                lock.unlock()
                out.size = Int64(plainSz)
            }
        } else if let sealPub = item.sealPublic,
                  let dropPrivWrap = keyManager.dropPrivateWrap,
                  let (sec, plainSz) = try? ZK.openDrop(sealed: sealPub, wrappedPrivateKey: dropPrivWrap, keys: keys) {
            lock.lock()
            secretsByID[item.id] = (sec, plainSz)
            lock.unlock()
            out.size = Int64(plainSz)
        }
        return out
    }

    private func decryptChange(_ entry: ChangeEntry) -> ChangeEntry {
        guard let keys = keyManager.keys else { return entry }
        var out = entry
        if let enc = entry.encName, let unlockedName = try? ZK.unlockName(enc, keys: keys) {
            out.name = unlockedName
        }
        if let fk = entry.fileKey, let fn = entry.fileNonce {
            let wire = ZK.WireSecrets(fileKey: fk, fileNonce: fn, plainSize: entry.plainSize ?? (entry.size ?? 0))
            if let (sec, plainSz) = try? ZK.unwrapFileSecrets(wire, with: keys) {
                lock.lock()
                secretsByID[entry.fileID] = (sec, plainSz)
                lock.unlock()
                out.size = Int64(plainSz)
            }
        }
        return out
    }

    public func cachedSecrets(for remoteID: String) -> (secrets: ZK.FileSecrets, plainSize: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        return secretsByID[remoteID]
    }

    // MARK: - DriveRemote Conformance

    public func listDirectory(parentID: String?) async throws -> [FileItem] {
        let raw = try await inner.listDirectory(parentID: parentID)
        return raw.map(decryptItem)
    }

    public func allFiles() async throws -> [FileItem] {
        let raw = try await inner.allFiles()
        return raw.map(decryptItem)
    }

    public func changes(since cursor: Int64) async throws -> ChangePage {
        let page = try await inner.changes(since: cursor)
        return ChangePage(
            changes: page.changes.map(decryptChange),
            cursor: page.cursor,
            hasMore: page.hasMore
        )
    }

    public func getItem(id: String) async throws -> FileItem {
        let raw = try await inner.getItem(id: id)
        return decryptItem(raw)
    }

    public func createDirectory(name: String, parentID: String?) async throws -> FileItem {
        if let keys = keyManager.keys {
            let wire = try ZK.lockName(name, parentID: parentID, keys: keys)
            let created = try await inner.createDirectoryWire(name: "folder", parentID: parentID, wire: wire)
            return decryptItem(created)
        }
        return try await inner.createDirectory(name: name, parentID: parentID)
    }

    public func rename(id: String, newName: String, parentID: String?) async throws -> FileItem {
        if let keys = keyManager.keys {
            let wire = try ZK.lockName(newName, parentID: parentID, keys: keys)
            let updated = try await inner.renameWire(id: id, newName: "item", wire: wire)
            return decryptItem(updated)
        }
        return try await inner.rename(id: id, newName: newName, parentID: parentID)
    }

    public func move(id: String, newParentID: String?, currentName: String) async throws -> FileItem {
        if let keys = keyManager.keys {
            let wire = try ZK.lockName(currentName, parentID: newParentID, keys: keys)
            let moved = try await inner.moveWire(id: id, newParentID: newParentID, wire: wire)
            return decryptItem(moved)
        }
        return try await inner.move(id: id, newParentID: newParentID, currentName: currentName)
    }

    public func delete(id: String) async throws {
        _ = lock.withLock {
            secretsByID.removeValue(forKey: id)
        }
        try await inner.delete(id: id)
    }

    public func updateTimestamps(id: String, createdAt: Date?, modifiedAt: Date?) async throws {
        try await inner.updateTimestamps(id: id, createdAt: createdAt, modifiedAt: modifiedAt)
    }

    public func fetchRange(remoteID: String, range: Range<UInt64>) async throws -> Data {
        guard keyManager.keys != nil else {
            return try await inner.fetchRange(remoteID: remoteID, range: range)
        }

        // Resolve FileSecrets from cache or fetch item metadata on miss
        let entry: (secrets: ZK.FileSecrets, plainSize: UInt64)? = try await {
            if let hit = cachedSecrets(for: remoteID) {
                return hit
            }
            _ = try await getItem(id: remoteID)
            return cachedSecrets(for: remoteID)
        }()

        guard let (secrets, plainSize) = entry else {
            // Unsealed legacy file fallback
            return try await inner.fetchRange(remoteID: remoteID, range: range)
        }

        let offset = range.lowerBound
        let length = Int(range.upperBound - range.lowerBound)
        guard length > 0, offset < plainSize else { return Data() }

        let plan = ZK.plainRange(offset: offset, length: length, plainSize: plainSize)
        let cipherRange = plan.cipherOffset..<(plan.cipherOffset + UInt64(plan.cipherLength))
        let cipherData = try await inner.fetchRange(remoteID: remoteID, range: cipherRange)

        let totalPieces = ZK.pieceCount(plainSize: plainSize)
        let cipherPieceSize = ZK.piece + ZK.tag
        var cursor = 0
        var plainCombined = Data(capacity: (plan.lastPiece - plan.firstPiece + 1) * ZK.piece)

        for pieceIdx in plan.firstPiece...plan.lastPiece {
            let isLast = (pieceIdx == totalPieces - 1)
            let expectedCipherLen: Int
            if isLast {
                let remPlain = Int(plainSize - UInt64(pieceIdx * ZK.piece))
                expectedCipherLen = remPlain + ZK.tag
            } else {
                expectedCipherLen = cipherPieceSize
            }
            let sliceEnd = min(cipherData.count, cursor + expectedCipherLen)
            guard cursor < sliceEnd else { throw ZKError.invalidCiphertext }
            let pieceCipher = cipherData.subdata(in: cursor..<sliceEnd)
            let unlocked = try ZK.unlockPiece(pieceCipher, index: pieceIdx, last: isLast, secrets: secrets)
            plainCombined.append(unlocked)
            cursor = sliceEnd
        }

        let firstPiecePlainStart = UInt64(plan.firstPiece) * UInt64(ZK.piece)
        let localStart = Int(offset - firstPiecePlainStart)
        let localEnd = min(plainCombined.count, localStart + length)
        guard localStart < localEnd else { return Data() }
        return plainCombined.subdata(in: localStart..<localEnd)
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
        guard let keys = keyManager.keys else {
            return try await inner.uploadFile(
                existingRemoteID: existingRemoteID,
                name: name,
                parentID: parentID,
                source: source,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                onProgress: onProgress
            )
        }

        let wireName = try ZK.lockName(name, parentID: parentID, keys: keys)
        let fileSecrets = ZK.newFileSecrets()
        let plainSize = source.totalSize
        let wireSecrets = try ZK.wrapFileSecrets(fileSecrets, plainSize: plainSize, with: keys)
        let lockedSource = LockedBlobSource(inner: source, secrets: fileSecrets)

        let res = try await inner.uploadFileWire(
            existingRemoteID: existingRemoteID,
            name: "file",
            parentID: parentID,
            source: lockedSource,
            wire: wireName,
            secrets: wireSecrets,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            onProgress: onProgress
        )

        lock.withLock {
            secretsByID[res.id] = (fileSecrets, plainSize)
        }

        return UploadResult(
            id: res.id,
            name: name,
            size: Int64(plainSize),
            parentID: parentID,
            updatedAt: res.updatedAt
        )
    }
}

// MARK: - PrivacySweep Actor (Background Migration of Unsealed Files to E2EE)

public actor PrivacySweep {
    private let remote: WireRemote
    private let keyManager: KeyManager

    public init(remote: WireRemote, keyManager: KeyManager) {
        self.remote = remote
        self.keyManager = keyManager
    }

    public func runSweep(onProgress: (@Sendable (SweepProgress) -> Void)? = nil) async throws -> SweepProgress {
        guard let keys = keyManager.keys else {
            return SweepProgress(total: 0, done: 0)
        }
        let unsealed = try await remote.unsealedFiles()
        let total = unsealed.count
        guard total > 0 else {
            return SweepProgress(total: 0, done: 0)
        }

        var done = 0
        keyManager.setMigrating(SweepProgress(total: total, done: 0))

        for item in unsealed {
            let wireName = try ZK.lockName(item.name, parentID: item.parentID, keys: keys)
            if item.isDirectory {
                try await remote.lockFileBatch([
                    LockedFileEntry(id: item.id, encName: wireName.encName, nameHash: wireName.nameHash)
                ])
            } else {
                let plainSize = UInt64(max(0, item.size))
                let plainData = plainSize > 0
                    ? try await remote.fetchRange(remoteID: item.id, range: 0..<plainSize)
                    : Data()
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sweep_\(item.id).bin")
                try plainData.write(to: tempURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: tempURL) }

                let fileSource = try FileBlobSource(fileURL: tempURL)
                let secrets = ZK.newFileSecrets()
                let wireSecrets = try ZK.wrapFileSecrets(secrets, plainSize: plainSize, with: keys)
                let lockedSource = LockedBlobSource(inner: fileSource, secrets: secrets)

                try await remote.putEncryptedFileContent(id: item.id, source: lockedSource, secrets: wireSecrets)
                try await remote.lockFileBatch([
                    LockedFileEntry(
                        id: item.id,
                        encName: wireName.encName,
                        nameHash: wireName.nameHash,
                        fileKey: wireSecrets.fileKey,
                        fileNonce: wireSecrets.fileNonce,
                        plainSize: wireSecrets.plainSize
                    )
                ])
            }
            done += 1
            let prog = SweepProgress(total: total, done: done)
            keyManager.setMigrating(prog)
            onProgress?(prog)
        }

        keyManager.setMigrating(nil)
        return SweepProgress(total: total, done: done)
    }
}
