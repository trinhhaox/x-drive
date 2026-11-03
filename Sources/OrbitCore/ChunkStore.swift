import Foundation

// MARK: - ChunkKey & ChunkStore (1 MiB Block Cache with Smart Eviction)

public struct ChunkKey: Hashable, Codable, Sendable {
    public var remoteID: String
    public var version: UInt64
    public var index: Int

    public init(remoteID: String, version: UInt64, index: Int) {
        self.remoteID = remoteID
        self.version = version
        self.index = index
    }

    public var fileName: String {
        "\(remoteID)_v\(version)_c\(index).chunk"
    }
}

public final class ChunkStore: @unchecked Sendable {
    // Exact reconstructed constant from OrbitCore.ChunkStore.defaultChunkSize (0x100131910)
    public static let defaultChunkSize: Int = 1_048_576 // 1 MiB

    public struct Limits: Equatable, Sendable {
        public var maxBytes: UInt64
        public var minFreeBytes: UInt64
        public var streamingBytes: UInt64
        public var criticalFreeBytes: UInt64
        public var lastResortBytes: UInt64
        public var outOfSpaceFreeBytes: UInt64

        public init(
            maxBytes: UInt64 = 10 * 1024 * 1024 * 1024,          // 10 GiB
            minFreeBytes: UInt64 = 5 * 1024 * 1024 * 1024,       // 5 GiB
            streamingBytes: UInt64 = 512 * 1024 * 1024,          // 512 MiB
            criticalFreeBytes: UInt64 = 2 * 1024 * 1024 * 1024,  // 2 GiB
            lastResortBytes: UInt64 = 128 * 1024 * 1024,         // 128 MiB
            outOfSpaceFreeBytes: UInt64 = 512 * 1024 * 1024      // 512 MiB
        ) {
            self.maxBytes = maxBytes
            self.minFreeBytes = minFreeBytes
            self.streamingBytes = streamingBytes
            self.criticalFreeBytes = criticalFreeBytes
            self.lastResortBytes = lastResortBytes
            self.outOfSpaceFreeBytes = outOfSpaceFreeBytes
        }
    }

    private struct EntryMeta {
        var key: ChunkKey
        var size: UInt64
        var lastAccess: Date
    }

    private let lock = NSLock()
    public let baseDirectory: URL
    public let chunkSize: Int
    private var limits: Limits
    private var entries: [ChunkKey: EntryMeta] = [:]
    private var pinnedRemoteIDs: Set<String> = []
    private var _totalBytes: UInt64 = 0
    private var freeSpaceProvider: () -> UInt64

    public init(
        baseDirectory: URL,
        chunkSize: Int = ChunkStore.defaultChunkSize,
        limits: Limits = Limits(),
        freeSpaceProvider: (() -> UInt64)? = nil
    ) {
        self.baseDirectory = baseDirectory
        self.chunkSize = chunkSize
        self.limits = limits
        self.freeSpaceProvider = freeSpaceProvider ?? { ChunkStore.systemFreeBytes(at: baseDirectory) }
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        scanExistingChunks()
    }

    public static func systemFreeBytes(at url: URL) -> UInt64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage,
           free > 0 {
            return UInt64(free)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            return free.uint64Value
        }
        return 50 * 1024 * 1024 * 1024
    }

    public var totalBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _totalBytes
    }

    public var pinnedBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return entries.values
            .filter { pinnedRemoteIDs.contains($0.key.remoteID) }
            .reduce(0) { $0 + $1.size }
    }

    public func setLimits(_ newLimits: Limits) {
        lock.lock()
        limits = newLimits
        lock.unlock()
        evictIfNeeded()
    }

    public func setPinnedRemoteIDs(_ ids: Set<String>) {
        lock.lock()
        pinnedRemoteIDs = ids
        lock.unlock()
        evictIfNeeded()
    }

    public func get(_ key: ChunkKey) -> Data? {
        let fileURL = baseDirectory.appendingPathComponent(key.fileName)
        lock.lock()
        guard var meta = entries[key] else {
            lock.unlock()
            return nil
        }
        meta.lastAccess = Date()
        entries[key] = meta
        lock.unlock()
        return try? Data(contentsOf: fileURL)
    }

    public func put(_ key: ChunkKey, data: Data) {
        let fileURL = baseDirectory.appendingPathComponent(key.fileName)
        let size = UInt64(data.count)

        lock.lock()
        let free = freeSpaceProvider()
        if free < limits.outOfSpaceFreeBytes && !pinnedRemoteIDs.contains(key.remoteID) {
            lock.unlock()
            evictIfNeeded()
            return
        }
        lock.unlock()

        do {
            try data.write(to: fileURL, options: .atomic)
            lock.lock()
            if let old = entries[key] {
                _totalBytes = _totalBytes >= old.size ? _totalBytes - old.size : 0
            }
            entries[key] = EntryMeta(key: key, size: size, lastAccess: Date())
            _totalBytes += size
            lock.unlock()
            evictIfNeeded()
        } catch {
            // Ignore write failure on disk pressure
        }
    }

    public func seedFromFile(url: URL, remoteID: String, version: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var index = 0
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            put(ChunkKey(remoteID: remoteID, version: version, index: index), data: chunk)
            if chunk.count < chunkSize { break }
            index += 1
        }
    }

    public func invalidate(remoteID: String, keepVersion: UInt64? = nil) {
        lock.lock()
        let toRemove = entries.keys.filter {
            $0.remoteID == remoteID && (keepVersion == nil || $0.version != keepVersion!)
        }
        for key in toRemove {
            if let meta = entries.removeValue(forKey: key) {
                _totalBytes = _totalBytes >= meta.size ? _totalBytes - meta.size : 0
            }
            let fileURL = baseDirectory.appendingPathComponent(key.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        lock.unlock()
    }

    public func clearAll(includePinned: Bool = false) {
        lock.lock()
        let keysToDelete = entries.keys.filter { includePinned || !pinnedRemoteIDs.contains($0.remoteID) }
        for key in keysToDelete {
            if let meta = entries.removeValue(forKey: key) {
                _totalBytes = _totalBytes >= meta.size ? _totalBytes - meta.size : 0
            }
            try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(key.fileName))
        }
        lock.unlock()
    }

    public func cachedRemoteIDs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(Set(entries.keys.map(\.remoteID))).sorted()
    }

    public func effectiveCeiling() -> UInt64 {
        let free = freeSpaceProvider()
        if free < limits.outOfSpaceFreeBytes {
            return 0
        }
        if free < limits.criticalFreeBytes {
            return min(limits.maxBytes, limits.lastResortBytes)
        }
        if free < limits.minFreeBytes {
            return min(limits.maxBytes, limits.streamingBytes)
        }
        return limits.maxBytes
    }

    public func evictIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        let ceiling = effectiveCeiling()
        guard _totalBytes > ceiling else { return }

        // Sort unpinned chunks by oldest lastAccess first
        let candidates = entries.values
            .filter { !pinnedRemoteIDs.contains($0.key.remoteID) }
            .sorted { $0.lastAccess < $1.lastAccess }

        for candidate in candidates {
            if _totalBytes <= ceiling { break }
            entries.removeValue(forKey: candidate.key)
            _totalBytes = _totalBytes >= candidate.size ? _totalBytes - candidate.size : 0
            let fileURL = baseDirectory.appendingPathComponent(candidate.key.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func scanExistingChunks() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        for url in urls where url.pathExtension == "chunk" {
            let base = url.deletingPathExtension().lastPathComponent
            let parts = base.components(separatedBy: "_v")
            guard parts.count == 2 else { continue }
            let remoteID = parts[0]
            let sub = parts[1].components(separatedBy: "_c")
            guard sub.count == 2,
                  let version = UInt64(sub[0]),
                  let index = Int(sub[1]) else { continue }
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = UInt64(vals?.fileSize ?? 0)
            let mod = vals?.contentModificationDate ?? Date()
            let key = ChunkKey(remoteID: remoteID, version: version, index: index)
            entries[key] = EntryMeta(key: key, size: size, lastAccess: mod)
            _totalBytes += size
        }
    }
}
