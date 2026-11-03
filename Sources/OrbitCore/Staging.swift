import Foundation

// MARK: - Staging (Write-Back Local File Buffer)

public final class Staging: @unchecked Sendable {
    public let baseDirectory: URL
    private let lock = NSLock()

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    public func fileURL(for nodeID: UInt64) -> URL {
        baseDirectory.appendingPathComponent("stage_\(nodeID).bin")
    }

    public func hasStagedFile(nodeID: UInt64) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: nodeID).path)
    }

    @discardableResult
    public func ensureStagedFile(nodeID: UInt64, initialData: Data? = nil) throws -> URL {
        let url = fileURL(for: nodeID)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: url.path) {
            try (initialData ?? Data()).write(to: url, options: .atomic)
        }
        return url
    }

    public func read(nodeID: UInt64, offset: UInt64, length: Int) throws -> Data {
        let url = fileURL(for: nodeID)
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    @discardableResult
    public func write(nodeID: UInt64, data: Data, offset: UInt64) throws -> UInt64 {
        let url = try ensureStagedFile(nodeID: nodeID)
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let currentEnd = try handle.seekToEnd()
        if offset > currentEnd {
            let zeroGap = Data(repeating: 0, count: Int(offset - currentEnd))
            try handle.write(contentsOf: zeroGap)
        } else {
            try handle.seek(toOffset: offset)
        }
        try handle.write(contentsOf: data)
        return try handle.seekToEnd()
    }

    @discardableResult
    public func truncate(nodeID: UInt64, size: UInt64) throws -> UInt64 {
        let url = try ensureStagedFile(nodeID: nodeID)
        lock.lock()
        defer { lock.unlock() }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
        return size
    }

    public func stagedSize(nodeID: UInt64) -> UInt64? {
        let url = fileURL(for: nodeID)
        guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let sz = vals.fileSize else { return nil }
        return UInt64(sz)
    }

    public func discard(nodeID: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(for: nodeID))
    }
}

// MARK: - BlobSource, FileBlobSource & LockedBlobSource (Streaming Encryption)

public protocol BlobSource: Sendable {
    var totalSize: UInt64 { get }
    func readSlice(offset: UInt64, length: Int) throws -> Data
}

public final class FileBlobSource: BlobSource, @unchecked Sendable {
    public let fileURL: URL
    public let totalSize: UInt64

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.totalSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }

    public func readSlice(offset: UInt64, length: Int) throws -> Data {
        guard length > 0, offset < totalSize else { return Data() }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}

/// Streams encrypted 1 MiB pieces (`1_048_592` bytes per cipher piece) on demand from a plaintext `BlobSource`.
public final class LockedBlobSource: BlobSource, @unchecked Sendable {
    private let inner: BlobSource
    public let secrets: ZK.FileSecrets
    public let plainSize: UInt64
    public let totalSize: UInt64
    private let totalPieces: Int
    private let lock = NSLock()
    private var cachedPieceIndex: Int?
    private var cachedCipherPiece: Data?

    public init(inner: BlobSource, secrets: ZK.FileSecrets) {
        self.inner = inner
        self.secrets = secrets
        self.plainSize = inner.totalSize
        self.totalSize = ZK.cipherSize(plainSize: inner.totalSize)
        self.totalPieces = ZK.pieceCount(plainSize: inner.totalSize)
    }

    private func encryptedPiece(at index: Int) throws -> Data {
        lock.lock()
        if cachedPieceIndex == index, let cached = cachedCipherPiece {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let plainOffset = UInt64(index) * UInt64(ZK.piece)
        let plainSlice: Data
        if plainSize == 0 {
            plainSlice = Data()
        } else {
            let len = Int(min(UInt64(ZK.piece), plainSize - plainOffset))
            plainSlice = try inner.readSlice(offset: plainOffset, length: len)
        }
        let isLast = (index == totalPieces - 1)
        let encrypted = try ZK.lockPiece(plainSlice, index: index, last: isLast, secrets: secrets)

        lock.lock()
        cachedPieceIndex = index
        cachedCipherPiece = encrypted
        lock.unlock()
        return encrypted
    }

    public func readSlice(offset: UInt64, length: Int) throws -> Data {
        guard length > 0, offset < totalSize else { return Data() }
        let cipherPieceSize = UInt64(ZK.piece + ZK.tag)
        let endOffset = min(totalSize, offset + UInt64(length))
        let startPiece = Int(offset / cipherPieceSize)
        let endPiece = Int((endOffset - 1) / cipherPieceSize)

        var output = Data(capacity: Int(endOffset - offset))
        for p in startPiece...endPiece {
            let pieceData = try encryptedPiece(at: p)
            let pieceStartGlobal = UInt64(p) * cipherPieceSize
            let sliceStart = offset > pieceStartGlobal ? Int(offset - pieceStartGlobal) : 0
            let sliceEnd = min(pieceData.count, Int(endOffset - pieceStartGlobal))
            if sliceStart < sliceEnd {
                output.append(pieceData.subdata(in: sliceStart..<sliceEnd))
            }
        }
        return output
    }
}

