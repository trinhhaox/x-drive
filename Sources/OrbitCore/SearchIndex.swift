import Foundation

// MARK: - SearchIndex (Instant Spotlight-Style In-Memory Search)

public final class SearchIndex: @unchecked Sendable {
    public struct Node: Equatable, Identifiable, Sendable {
        public var id: UInt64
        public var name: String
        public var lowerName: String
        public var relativePath: String
        public var isDirectory: Bool
        public var size: UInt64
        public var modifiedAt: Date

        public init(
            id: UInt64,
            name: String,
            relativePath: String,
            isDirectory: Bool,
            size: UInt64,
            modifiedAt: Date
        ) {
            self.id = id
            self.name = name
            self.lowerName = name.lowercased()
            self.relativePath = relativePath
            self.isDirectory = isDirectory
            self.size = size
            self.modifiedAt = modifiedAt
        }
    }

    private let lock = NSLock()
    private var entries: [Node] = []
    private var loadedAt: Date = .distantPast

    public init() {}

    public func rebuild(from tree: DriveTree) {
        let all = tree.allNodesSnapshot()
        var built: [Node] = []
        built.reserveCapacity(all.count)
        for item in all where item.id != DriveTree.rootID {
            let rel = tree.relativePath(of: item.id) ?? "/\(item.name)"
            built.append(
                Node(
                    id: item.id,
                    name: item.name,
                    relativePath: rel,
                    isDirectory: item.kind == .directory,
                    size: item.size,
                    modifiedAt: item.modifiedAt
                )
            )
        }
        lock.lock()
        self.entries = built
        self.loadedAt = Date()
        lock.unlock()
    }

    public func reloadFromSharedSnapshotIfNeeded() {
        let tree = DriveTree()
        if tree.load(from: SharedContainer.treeFile) {
            rebuild(from: tree)
        }
    }

    public func search(query: String, limit: Int = 50) -> [Node] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            lock.lock()
            let recent = entries.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(limit)
            lock.unlock()
            return Array(recent)
        }

        let tokens = trimmed.split(separator: " ").map(String.init)
        lock.lock()
        let snapshot = entries
        lock.unlock()

        var scored: [(node: Node, score: Int)] = []
        for node in snapshot {
            var matchedAll = true
            var score = 0
            for tok in tokens {
                if node.lowerName == tok {
                    score += 100
                } else if node.lowerName.hasPrefix(tok) {
                    score += 60
                } else if node.lowerName.contains(tok) {
                    score += 30
                } else if node.relativePath.lowercased().contains(tok) {
                    score += 10
                } else {
                    matchedAll = false
                    break
                }
            }
            if matchedAll {
                scored.append((node, score))
            }
        }

        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.node.modifiedAt > $1.node.modifiedAt
        }
        return Array(scored.prefix(limit).map(\.node))
    }
}

