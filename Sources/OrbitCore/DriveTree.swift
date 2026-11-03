import Foundation

// MARK: - DriveTree (Thread-Safe Virtual Inode Tree)

public final class DriveTree: @unchecked Sendable {
    public static let rootID: UInt64 = 1

    private let lock = NSLock()
    private var nextID: UInt64 = 2
    private var nodes: [UInt64: DriveNode] = [:]
    private var children: [UInt64: [String: UInt64]] = [:]
    private var byRemoteID: [String: UInt64] = [:]
    private var populatedDirs: Set<UInt64> = []
    private var pendingDeletes: [(remoteID: String, isDirectory: Bool)] = []
    private var _lastChangeSeq: Int64 = 0

    public init() {
        let now = Date()
        let root = DriveNode(
            id: Self.rootID,
            remoteID: nil,
            parentID: Self.rootID,
            name: "",
            kind: .directory,
            size: 0,
            createdAt: now,
            modifiedAt: now,
            dirty: false,
            contentVersion: 1
        )
        nodes[Self.rootID] = root
        children[Self.rootID] = [:]
    }

    public var lastChangeSeq: Int64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastChangeSeq
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _lastChangeSeq = newValue
        }
    }

    // MARK: - Lookups

    public func node(id: UInt64) -> DriveNode? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[id]
    }

    public func node(remoteID: String) -> DriveNode? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = byRemoteID[remoteID] else { return nil }
        return nodes[id]
    }

    public func lookup(name: String, inParent parentID: UInt64) -> DriveNode? {
        lock.lock()
        defer { lock.unlock() }
        guard let childID = children[parentID]?[name] else { return nil }
        return nodes[childID]
    }

    public func lookupPath(_ relativePath: String) -> DriveNode? {
        lock.lock()
        defer { lock.unlock() }
        let parts = relativePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        var currentID = Self.rootID
        for part in parts {
            guard let next = children[currentID]?[part] else { return nil }
            currentID = next
        }
        return nodes[currentID]
    }

    public func relativePath(of id: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard nodes[id] != nil else { return nil }
        if id == Self.rootID { return "/" }
        var components: [String] = []
        var cur = id
        var guardCounter = 0
        while cur != Self.rootID && guardCounter < 256 {
            guard let n = nodes[cur] else { return nil }
            components.append(n.name)
            cur = n.parentID
            guardCounter += 1
        }
        return "/" + components.reversed().joined(separator: "/")
    }

    public func listChildren(of parentID: UInt64) -> [DriveNode] {
        lock.lock()
        defer { lock.unlock() }
        guard let map = children[parentID] else { return [] }
        return map.values.compactMap { nodes[$0] }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func isPopulated(dirID: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return populatedDirs.contains(dirID)
    }

    // MARK: - Local Mutations (POSIX / FSKit Operations)

    @discardableResult
    public func createLocal(
        name: String,
        parentID: UInt64,
        kind: NodeKind,
        symlinkTarget: String? = nil
    ) -> DriveNode {
        lock.lock()
        defer { lock.unlock() }
        if let existingID = children[parentID]?[name], let existing = nodes[existingID] {
            return existing
        }
        let id = nextID
        nextID += 1
        let now = Date()
        let node = DriveNode(
            id: id,
            remoteID: nil,
            parentID: parentID,
            name: name,
            kind: kind,
            size: kind == .symlink ? UInt64((symlinkTarget ?? "").utf8.count) : 0,
            createdAt: now,
            modifiedAt: now,
            dirty: kind == .file,
            contentVersion: 1,
            symlinkTarget: symlinkTarget,
            metadataPending: true,
            isLink: false
        )
        nodes[id] = node
        children[parentID, default: [:]][name] = id
        if kind == .directory {
            children[id] = [:]
            populatedDirs.insert(id)
        }
        return node
    }

    public func createHardLink(targetID: UInt64, name: String, parentID: UInt64) -> DriveNode? {
        lock.lock()
        defer { lock.unlock() }
        guard let target = nodes[targetID], target.kind == .file else { return nil }
        let id = nextID
        nextID += 1
        var linked = target
        linked.id = id
        linked.parentID = parentID
        linked.name = name
        linked.isLink = true
        nodes[id] = linked
        children[parentID, default: [:]][name] = id
        return linked
    }

    public func updateSize(id: UInt64, size: UInt64, markDirty: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard var node = nodes[id] else { return }
        node.size = size
        node.modifiedAt = Date()
        if markDirty {
            node.dirty = true
            node.contentVersion &+= 1
        }
        nodes[id] = node
    }

    public func updateTimestamps(id: UInt64, created: Date?, modified: Date?) {
        lock.lock()
        defer { lock.unlock() }
        guard var node = nodes[id] else { return }
        if let created { node.createdAt = created }
        if let modified { node.modifiedAt = modified }
        node.metadataPending = true
        nodes[id] = node
    }

    public func rename(id: UInt64, newParentID: UInt64, newName: String) -> DriveNode? {
        lock.lock()
        defer { lock.unlock() }
        guard var node = nodes[id] else { return nil }
        // Remove overwritten target if different
        if let existingID = children[newParentID]?[newName], existingID != id {
            removeSubtreeLocked(id: existingID)
        }
        children[node.parentID]?.removeValue(forKey: node.name)
        node.parentID = newParentID
        node.name = newName
        node.modifiedAt = Date()
        node.metadataPending = true
        nodes[id] = node
        children[newParentID, default: [:]][newName] = id
        return node
    }

    public func remove(id: UInt64) -> DriveNode? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[id], id != Self.rootID else { return nil }
        removeSubtreeLocked(id: id)
        return node
    }

    private func removeSubtreeLocked(id: UInt64) {
        guard let node = nodes[id] else { return }
        if let childMap = children[id] {
            for childID in childMap.values {
                removeSubtreeLocked(id: childID)
            }
        }
        children[node.parentID]?.removeValue(forKey: node.name)
        children.removeValue(forKey: id)
        populatedDirs.remove(id)
        if let remID = node.remoteID {
            byRemoteID.removeValue(forKey: remID)
            pendingDeletes.append((remoteID: remID, isDirectory: node.kind == .directory))
        }
        nodes.removeValue(forKey: id)
    }

    // MARK: - Remote Synchronization & Delta Application

    public func markSynced(id: UInt64, remoteID: String, clearDirty: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard var node = nodes[id] else { return }
        if let oldRemote = node.remoteID {
            byRemoteID.removeValue(forKey: oldRemote)
        }
        node.remoteID = remoteID
        node.metadataPending = false
        if clearDirty {
            node.dirty = false
        }
        nodes[id] = node
        byRemoteID[remoteID] = id
    }

    public func populate(dirID: UInt64, remoteItems: [FileItem]) {
        lock.lock()
        defer { lock.unlock() }
        for item in remoteItems {
            upsertRemoteItemLocked(item, parentNodeID: dirID)
        }
        populatedDirs.insert(dirID)
    }

    public func populateAll(remoteItems: [FileItem]) {
        lock.lock()
        defer { lock.unlock() }
        // First pass: directories and root items
        var pending = remoteItems
        var progress = true
        while !pending.isEmpty && progress {
            progress = false
            var nextBatch: [FileItem] = []
            for item in pending {
                let parentNodeID: UInt64?
                if let pid = item.parentID {
                    parentNodeID = byRemoteID[pid]
                } else {
                    parentNodeID = Self.rootID
                }
                if let resolvedParent = parentNodeID {
                    upsertRemoteItemLocked(item, parentNodeID: resolvedParent)
                    progress = true
                } else {
                    nextBatch.append(item)
                }
            }
            pending = nextBatch
        }
        // Any remaining orphans attach to root
        for item in pending {
            upsertRemoteItemLocked(item, parentNodeID: Self.rootID)
        }
        for (id, node) in nodes where node.kind == .directory {
            populatedDirs.insert(id)
        }
    }

    @discardableResult
    private func upsertRemoteItemLocked(_ item: FileItem, parentNodeID: UInt64) -> (nodeID: UInt64, contentChanged: Bool) {
        let effectiveSize = UInt64(max(0, item.plainSize ?? item.size))
        if let existingID = byRemoteID[item.id], var existing = nodes[existingID] {
            if existing.dirty {
                return (existingID, false)
            }
            let sizeOrDateChanged = existing.size != effectiveSize || abs(existing.modifiedAt.timeIntervalSince(item.updatedAt)) > 0.001
            if existing.parentID != parentNodeID || existing.name != item.name {
                children[existing.parentID]?.removeValue(forKey: existing.name)
                children[parentNodeID, default: [:]][item.name] = existingID
            }
            existing.parentID = parentNodeID
            existing.name = item.name
            existing.size = effectiveSize
            existing.modifiedAt = item.updatedAt
            if sizeOrDateChanged && existing.kind == .file {
                existing.contentVersion &+= 1
            }
            nodes[existingID] = existing
            return (existingID, sizeOrDateChanged)
        }

        // Check if there is an unlinked local node with the same name in parent
        if let localID = children[parentNodeID]?[item.name], var local = nodes[localID], local.remoteID == nil {
            local.remoteID = item.id
            if !local.dirty {
                local.size = effectiveSize
                local.modifiedAt = item.updatedAt
            }
            nodes[localID] = local
            byRemoteID[item.id] = localID
            return (localID, false)
        }

        let id = nextID
        nextID += 1
        let kind: NodeKind = item.isDirectory ? .directory : .file
        let node = DriveNode(
            id: id,
            remoteID: item.id,
            parentID: parentNodeID,
            name: item.name,
            kind: kind,
            size: effectiveSize,
            createdAt: item.createdAt,
            modifiedAt: item.updatedAt,
            dirty: false,
            contentVersion: 1
        )
        nodes[id] = node
        children[parentNodeID, default: [:]][item.name] = id
        if kind == .directory {
            children[id] = [:]
        }
        byRemoteID[item.id] = id
        return (id, true)
    }

    public func applyChanges(_ entries: [ChangeEntry]) -> ChangeSummary {
        lock.lock()
        defer { lock.unlock() }
        var contentChanged: [(remoteID: String, newVersion: UInt64)] = []
        var deletedRemoteIDs: [String] = []
        var treeChanged = false

        for entry in entries {
            if entry.seq > _lastChangeSeq {
                _lastChangeSeq = entry.seq
            }
            if entry.action == "delete" {
                if let id = byRemoteID[entry.fileID], let node = nodes[id] {
                    children[node.parentID]?.removeValue(forKey: node.name)
                    children.removeValue(forKey: id)
                    byRemoteID.removeValue(forKey: entry.fileID)
                    nodes.removeValue(forKey: id)
                    deletedRemoteIDs.append(entry.fileID)
                    treeChanged = true
                }
            } else if entry.action == "upsert", let name = entry.name {
                let parentNodeID: UInt64
                if let pid = entry.parentID, let found = byRemoteID[pid] {
                    parentNodeID = found
                } else {
                    parentNodeID = Self.rootID
                }
                let item = FileItem(
                    id: entry.fileID,
                    name: name,
                    parentID: entry.parentID,
                    isDirectory: entry.isDirectory ?? false,
                    size: entry.size ?? 0,
                    createdAt: entry.createdAt ?? Date(),
                    updatedAt: entry.updatedAt ?? Date(),
                    encName: entry.encName,
                    fileKey: entry.fileKey,
                    fileNonce: entry.fileNonce,
                    plainSize: entry.plainSize,
                    sealPublic: entry.sealPublic
                )
                let (nid, changed) = upsertRemoteItemLocked(item, parentNodeID: parentNodeID)
                treeChanged = true
                if changed, let updated = nodes[nid], updated.kind == .file {
                    contentChanged.append((remoteID: entry.fileID, newVersion: updated.contentVersion))
                }
            }
        }
        return ChangeSummary(
            contentChanged: contentChanged,
            deletedRemoteIDs: deletedRemoteIDs,
            treeChanged: treeChanged
        )
    }

    public func dirtyNodes() -> [DriveNode] {
        lock.lock()
        defer { lock.unlock() }
        return nodes.values.filter { $0.dirty || $0.metadataPending }.sorted { $0.id < $1.id }
    }

    public func drainPendingDeletes() -> [(remoteID: String, isDirectory: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        let out = pendingDeletes
        pendingDeletes.removeAll()
        return out
    }

    public func allNodesSnapshot() -> [DriveNode] {
        lock.lock()
        defer { lock.unlock() }
        return Array(nodes.values)
    }

    // MARK: - Persistence (Snapshot Save / Load)

    private struct PersistedSnapshot: Codable {
        var nextID: UInt64
        var lastChangeSeq: Int64
        var nodes: [DriveNode]
        var populatedDirs: [UInt64]
    }

    public func save(to url: URL) throws {
        lock.lock()
        let snapshot = PersistedSnapshot(
            nextID: nextID,
            lastChangeSeq: _lastChangeSeq,
            nodes: Array(nodes.values),
            populatedDirs: Array(populatedDirs)
        )
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public func load(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(PersistedSnapshot.self, from: data) else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        self.nextID = max(2, snapshot.nextID)
        self._lastChangeSeq = snapshot.lastChangeSeq
        self.nodes.removeAll()
        self.children.removeAll()
        self.byRemoteID.removeAll()
        self.populatedDirs = Set(snapshot.populatedDirs)

        for n in snapshot.nodes {
            nodes[n.id] = n
            if n.kind == .directory {
                children[n.id, default: [:]] = children[n.id, default: [:]]
            }
            if n.id != Self.rootID {
                children[n.parentID, default: [:]][n.name] = n.id
            }
            if let rem = n.remoteID {
                byRemoteID[rem] = n.id
            }
        }
        return true
    }
}

// MARK: - XattrStore (Extended Attributes Persistence)

public final class XattrStore: @unchecked Sendable {
    private let lock = NSLock()
    private var attrs: [UInt64: [String: Data]] = [:]
    private let persistenceURL: URL?

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        if let url = persistenceURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([UInt64: [String: Data]].self, from: data) {
            self.attrs = decoded
        }
    }

    public func get(nodeID: UInt64, name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return attrs[nodeID]?[name]
    }

    public func set(nodeID: UInt64, name: String, value: Data?) {
        lock.lock()
        if let value {
            attrs[nodeID, default: [:]][name] = value
        } else {
            attrs[nodeID]?.removeValue(forKey: name)
        }
        let snapshot = attrs
        lock.unlock()
        persist(snapshot)
    }

    public func list(nodeID: UInt64) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let map = attrs[nodeID] else { return [] }
        return Array(map.keys).sorted()
    }

    public func removeAll(nodeID: UInt64) {
        lock.lock()
        attrs.removeValue(forKey: nodeID)
        let snapshot = attrs
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: [UInt64: [String: Data]]) {
        guard let url = persistenceURL else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

