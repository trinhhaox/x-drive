import Foundation

// MARK: - DriveRemote Protocol (Abstract Cloud Backend Interface)

public protocol DriveRemote: Sendable {
    func listDirectory(parentID: String?) async throws -> [FileItem]
    func allFiles() async throws -> [FileItem]
    func changes(since cursor: Int64) async throws -> ChangePage
    func getItem(id: String) async throws -> FileItem
    func createDirectory(name: String, parentID: String?) async throws -> FileItem
    func rename(id: String, newName: String, parentID: String?) async throws -> FileItem
    func move(id: String, newParentID: String?, currentName: String) async throws -> FileItem
    func delete(id: String) async throws
    func updateTimestamps(id: String, createdAt: Date?, modifiedAt: Date?) async throws
    func fetchRange(remoteID: String, range: Range<UInt64>) async throws -> Data
    func uploadFile(
        existingRemoteID: String?,
        name: String,
        parentID: String?,
        source: BlobSource,
        createdAt: Date?,
        modifiedAt: Date?,
        onProgress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UploadResult
}

// MARK: - ContentReader (Chunk-Aligned Range Reader & Sequential Prefetcher)

public final class ContentReader: @unchecked Sendable {
    private struct StreamState {
        var lastChunkIndex: Int
        var sequentialHits: Int
        var lastReadAt: Date
    }

    public let chunkStore: ChunkStore
    private let remote: DriveRemote
    private let lock = NSLock()
    private var streams: [String: StreamState] = [:]
    private var prefetching: Set<ChunkKey> = []
    public let maxPrefetchAhead: Int = 3

    public init(chunkStore: ChunkStore, remote: DriveRemote) {
        self.chunkStore = chunkStore
        self.remote = remote
    }

    public func read(
        remoteID: String,
        version: UInt64,
        fileSize: UInt64,
        offset: UInt64,
        length: Int
    ) async throws -> Data {
        guard length > 0, offset < fileSize else {
            return Data()
        }
        let endOffset = min(fileSize, offset + UInt64(length))
        let chunkSize = UInt64(chunkStore.chunkSize)
        let firstChunk = Int(offset / chunkSize)
        let lastChunk = Int((endOffset - 1) / chunkSize)

        var result = Data(capacity: Int(endOffset - offset))

        for chunkIdx in firstChunk...lastChunk {
            let chunkData = try await fetchChunk(
                remoteID: remoteID,
                version: version,
                fileSize: fileSize,
                chunkIndex: chunkIdx
            )
            let chunkGlobalStart = UInt64(chunkIdx) * chunkSize
            let sliceStart = offset > chunkGlobalStart ? Int(offset - chunkGlobalStart) : 0
            let sliceEnd = min(chunkData.count, Int(endOffset - chunkGlobalStart))
            if sliceStart < sliceEnd {
                result.append(chunkData.subdata(in: sliceStart..<sliceEnd))
            }
        }

        // Track sequential reading & trigger background read-ahead
        updateSequentialState(remoteID: remoteID, version: version, fileSize: fileSize, lastReadChunk: lastChunk)
        return result
    }

    public func fetchChunk(
        remoteID: String,
        version: UInt64,
        fileSize: UInt64,
        chunkIndex: Int
    ) async throws -> Data {
        let key = ChunkKey(remoteID: remoteID, version: version, index: chunkIndex)
        if let cached = chunkStore.get(key) {
            return cached
        }
        let chunkSize = UInt64(chunkStore.chunkSize)
        let start = UInt64(chunkIndex) * chunkSize
        guard start < fileSize else { return Data() }
        let end = min(fileSize, start + chunkSize)
        let data = try await remote.fetchRange(remoteID: remoteID, range: start..<end)
        chunkStore.put(key, data: data)
        return data
    }

    private func updateSequentialState(
        remoteID: String,
        version: UInt64,
        fileSize: UInt64,
        lastReadChunk: Int
    ) {
        let aheadCount: Int = {
            lock.lock()
            defer { lock.unlock() }
            let now = Date()
            if var st = streams[remoteID], now.timeIntervalSince(st.lastReadAt) < 15 {
                if lastReadChunk == st.lastChunkIndex + 1 || lastReadChunk == st.lastChunkIndex {
                    st.sequentialHits = min(10, st.sequentialHits + 1)
                } else {
                    st.sequentialHits = 0
                }
                st.lastChunkIndex = lastReadChunk
                st.lastReadAt = now
                streams[remoteID] = st
                return min(maxPrefetchAhead, st.sequentialHits)
            } else {
                streams[remoteID] = StreamState(lastChunkIndex: lastReadChunk, sequentialHits: 1, lastReadAt: now)
                return 0
            }
        }()

        guard aheadCount > 0 else { return }
        let totalChunks = Int((fileSize + UInt64(chunkStore.chunkSize) - 1) / UInt64(chunkStore.chunkSize))
        for step in 1...aheadCount {
            let targetIdx = lastReadChunk + step
            guard targetIdx < totalChunks else { break }
            let key = ChunkKey(remoteID: remoteID, version: version, index: targetIdx)
            lock.lock()
            if prefetching.contains(key) || chunkStore.get(key) != nil {
                lock.unlock()
                continue
            }
            prefetching.insert(key)
            lock.unlock()

            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = try? await self.fetchChunk(
                    remoteID: remoteID,
                    version: version,
                    fileSize: fileSize,
                    chunkIndex: targetIdx
                )
                self.finishPrefetch(key)
            }
        }
    }

    private func finishPrefetch(_ key: ChunkKey) {
        lock.lock()
        prefetching.remove(key)
        lock.unlock()
    }
}
