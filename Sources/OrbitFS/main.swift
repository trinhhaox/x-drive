import Foundation
import FSKit
import OrbitCore

// MARK: - OrbitFSItem (Native FSKit vnode Item)

@available(macOS 15.4, *)
public final class OrbitFSItem: FSItem, @unchecked Sendable {
    public let nodeID: UInt64

    public init(nodeID: UInt64) {
        self.nodeID = nodeID
        super.init()
    }
}

// MARK: - OrbitVolume (Full FSKit Volume Implementation Matching Helumi's OrbitVolume)

@available(macOS 15.4, *)
public final class OrbitVolume: FSVolume,
    FSVolume.Operations,
    FSVolume.PathConfOperations,
    FSVolume.OpenCloseOperations,
    FSVolume.ReadWriteOperations,
    FSVolume.XattrOperations,
    @unchecked Sendable
{
    public let drive: OrbitDrive
    public let ownerUID: uid_t
    public let ownerGID: gid_t
    private let itemLock = NSLock()
    private var items: [UInt64: OrbitFSItem] = [:]

    public init(
        volumeID: FSVolume.Identifier,
        volumeName: FSFileName,
        drive: OrbitDrive,
        ownerUID: uid_t = getuid(),
        ownerGID: gid_t = getgid()
    ) {
        self.drive = drive
        self.ownerUID = ownerUID
        self.ownerGID = ownerGID
        super.init(volumeID: volumeID, volumeName: volumeName)
        items[DriveTree.rootID] = OrbitFSItem(nodeID: DriveTree.rootID)
    }

    public func item(for nodeID: UInt64) -> OrbitFSItem {
        itemLock.withLock {
            if let existing = items[nodeID] {
                return existing
            }
            let created = OrbitFSItem(nodeID: nodeID)
            items[nodeID] = created
            return created
        }
    }

    // MARK: - PathConfOperations

    public var maximumLinkCount: Int { 255 }
    public var maximumNameLength: Int { 255 }
    public var restrictsOwnershipChanges: Bool { false }
    public var truncatesLongNames: Bool { false }
    public var maximumFileSize: UInt64 { 5 * 1024 * 1024 * 1024 * 1024 } // 5 TiB

    // MARK: - CommonOperations (Capabilities & StatFS)

    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = true
        caps.supportsSparseFiles = true
        caps.supportsFastStatFS = true
        caps.supports2TBFiles = true
        caps.supports64BitObjectIDs = true
        caps.supportsHiddenFiles = true
        caps.caseFormat = .insensitiveCasePreserving
        return caps
    }

    public var volumeStatistics: FSStatFSResult {
        let stat = FSStatFSResult(fileSystemTypeName: MountHelper.fileSystemType)
        let blockSz: UInt64 = 4096
        let totalBytes: UInt64 = 2 * 1024 * 1024 * 1024 * 1024 // 2 TiB
        let usedBytes: UInt64 = drive.chunkStore.totalBytes
        let freeBytes: UInt64 = totalBytes > usedBytes ? totalBytes - usedBytes : 0

        stat.blockSize = Int(blockSz)
        stat.ioSize = ChunkStore.defaultChunkSize
        stat.totalBytes = totalBytes
        stat.usedBytes = usedBytes
        stat.freeBytes = freeBytes
        stat.availableBytes = freeBytes
        stat.totalBlocks = totalBytes / blockSz
        stat.usedBlocks = usedBytes / blockSz
        stat.freeBlocks = freeBytes / blockSz
        stat.availableBlocks = freeBytes / blockSz
        stat.totalFiles = 1_000_000
        stat.freeFiles = 900_000
        return stat
    }

    public func mount(options: FSTaskOptions, replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    public func unmount(replyHandler reply: @escaping () -> Void) {
        drive.saveTreeSnapshot()
        drive.publishStatus()
        reply()
    }

    public func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping (Error?) -> Void) {
        drive.saveTreeSnapshot()
        drive.publishStatus()
        reply(nil)
    }

    public func reclaimItem(_ item: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        guard let orbitItem = item as? OrbitFSItem else {
            reply(nil)
            return
        }
        itemLock.withLock {
            if orbitItem.nodeID != DriveTree.rootID {
                _ = items.removeValue(forKey: orbitItem.nodeID)
            }
        }
        reply(nil)
    }

    // MARK: - Volume Activation & Deactivation

    public func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, Error?) -> Void) {
        let root = item(for: DriveTree.rootID)
        reply(root, nil)
    }

    public func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping (Error?) -> Void) {
        drive.saveTreeSnapshot()
        reply(nil)
    }

    // MARK: - Attributes Helper

    private func buildAttributes(for node: DriveNode) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.uid = ownerUID
        attrs.gid = ownerGID
        attrs.fileID = FSItem.Identifier(rawValue: node.id == DriveTree.rootID ? FSItem.Identifier.rootDirectory.rawValue : node.id) ?? .rootDirectory
        attrs.parentID = FSItem.Identifier(rawValue: node.id == DriveTree.rootID ? FSItem.Identifier.parentOfRoot.rawValue : node.parentID) ?? .parentOfRoot
        attrs.size = node.size
        attrs.allocSize = ((node.size + 4095) / 4096) * 4096
        attrs.linkCount = 1

        switch node.kind {
        case .directory:
            attrs.type = .directory
            attrs.mode = UInt32(S_IFDIR | 0o755)
        case .symlink:
            attrs.type = .symlink
            attrs.mode = UInt32(S_IFLNK | 0o777)
        case .file:
            attrs.type = .file
            attrs.mode = UInt32(S_IFREG | 0o644)
        }

        let modSec = Int(node.modifiedAt.timeIntervalSince1970)
        let crtSec = Int(node.createdAt.timeIntervalSince1970)
        let modSpec = timespec(tv_sec: modSec, tv_nsec: 0)
        let crtSpec = timespec(tv_sec: crtSec, tv_nsec: 0)
        attrs.modifyTime = modSpec
        attrs.changeTime = modSpec
        attrs.accessTime = modSpec
        attrs.birthTime = crtSpec
        return attrs
    }

    public func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem,
              let node = drive.tree.node(id: orbitItem.nodeID) else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            return
        }
        reply(buildAttributes(for: node), nil)
    }

    public func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem,
              let node = drive.tree.node(id: orbitItem.nodeID) else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            return
        }
        if newAttributes.isValid(.size) && node.kind == .file {
            let newSz = newAttributes.size
            _ = try? drive.staging.truncate(nodeID: orbitItem.nodeID, size: newSz)
            drive.tree.updateSize(id: orbitItem.nodeID, size: newSz, markDirty: true)
            newAttributes.consumedAttributes.insert(.size)
        }
        if newAttributes.isValid(.modifyTime) {
            let modDate = Date(timeIntervalSince1970: TimeInterval(newAttributes.modifyTime.tv_sec))
            drive.tree.updateTimestamps(id: orbitItem.nodeID, created: nil, modified: modDate)
            newAttributes.consumedAttributes.insert(.modifyTime)
        }
        let updated = drive.tree.node(id: orbitItem.nodeID) ?? node
        reply(buildAttributes(for: updated), nil)
    }

    // MARK: - Directory Lookup & Enumeration

    public func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let dirItem = directory as? OrbitFSItem,
              let nameStr = name.string else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            return
        }

        // Intercept `._helumi-refresh` control channel to trigger immediate delta sync
        if nameStr == SharedContainer.refreshDirectoryName || nameStr.hasPrefix("._helumi-refresh") {
            Task {
                _ = try? await drive.syncChanges()
                for req in SharedContainer.consumeRefreshRequests() where req != "all" {
                    if let target = drive.tree.node(remoteID: req) {
                        try? await drive.refreshDirectory(nodeID: target.id)
                    }
                }
                reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            }
            return
        }

        Task {
            _ = try? await drive.listDirectory(nodeID: dirItem.nodeID)
            guard let found = drive.tree.lookup(name: nameStr, inParent: dirItem.nodeID) else {
                reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
                return
            }
            let fsItem = self.item(for: found.id)
            reply(fsItem, FSFileName(string: found.name), nil)
        }
    }

    public func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping (FSDirectoryVerifier, Error?) -> Void
    ) {
        guard let dirItem = directory as? OrbitFSItem else {
            reply(FSDirectoryVerifier.initial, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            return
        }

        Task {
            let children = (try? await drive.listDirectory(nodeID: dirItem.nodeID)) ?? []
            let startIdx = cookie == FSDirectoryCookie.initial ? 0 : Int(cookie.rawValue)
            guard startIdx <= children.count else {
                reply(FSDirectoryVerifier(rawValue: 1), nil)
                return
            }

            for idx in startIdx..<children.count {
                let child = children[idx]
                let itemType: FSItem.ItemType
                switch child.kind {
                case .directory: itemType = .directory
                case .symlink: itemType = .symlink
                case .file: itemType = .file
                }
                let itemID = FSItem.Identifier(rawValue: child.id) ?? .invalid
                let nextCookie = FSDirectoryCookie(rawValue: UInt64(idx + 1))
                let entryAttrs = attributes != nil ? buildAttributes(for: child) : nil
                let packed = packer.packEntry(
                    name: FSFileName(string: child.name),
                    itemType: itemType,
                    itemID: itemID,
                    nextCookie: nextCookie,
                    attributes: entryAttrs
                )
                if !packed { break }
            }
            reply(FSDirectoryVerifier(rawValue: 1), nil)
        }
    }

    // MARK: - Create, Symlink, HardLink, Rename, Remove

    public func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let dirItem = directory as? OrbitFSItem,
              let nameStr = name.string else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        if drive.tree.lookup(name: nameStr, inParent: dirItem.nodeID) != nil {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST)))
            return
        }
        let kind: NodeKind = (type == .directory) ? .directory : .file
        Task {
            do {
                let created = try await drive.createItem(name: nameStr, parentID: dirItem.nodeID, kind: kind)
                let fsItem = self.item(for: created.id)
                reply(fsItem, FSFileName(string: created.name), nil)
            } catch {
                reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            }
        }
    }

    public func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let dirItem = directory as? OrbitFSItem,
              let nameStr = name.string,
              let targetStr = contents.string else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        Task {
            do {
                let created = try await drive.createItem(
                    name: nameStr,
                    parentID: dirItem.nodeID,
                    kind: .symlink,
                    symlinkTarget: targetStr
                )
                let fsItem = self.item(for: created.id)
                reply(fsItem, FSFileName(string: created.name), nil)
            } catch {
                reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            }
        }
    }

    public func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSFileName?, Error?) -> Void
    ) {
        guard let targetItem = item as? OrbitFSItem,
              let dirItem = directory as? OrbitFSItem,
              let nameStr = name.string else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        guard let linked = drive.tree.createHardLink(targetID: targetItem.nodeID, name: nameStr, parentID: dirItem.nodeID) else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))
            return
        }
        reply(FSFileName(string: linked.name), nil)
    }

    public func readSymbolicLink(
        _ item: FSItem,
        replyHandler reply: @escaping (FSFileName?, Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem,
              let node = drive.tree.node(id: orbitItem.nodeID),
              node.kind == .symlink,
              let target = node.symlinkTarget else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        reply(FSFileName(string: target), nil)
    }

    public func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler reply: @escaping (FSFileName?, Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem,
              let destDir = destinationDirectory as? OrbitFSItem,
              let newNameStr = destinationName.string else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        Task {
            do {
                guard let renamed = try await drive.renameItem(
                    nodeID: orbitItem.nodeID,
                    newParentID: destDir.nodeID,
                    newName: newNameStr
                ) else {
                    reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
                    return
                }
                reply(FSFileName(string: renamed.name), nil)
            } catch {
                reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            }
        }
    }

    public func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            return
        }
        Task {
            try? await drive.removeItem(nodeID: orbitItem.nodeID)
            reply(nil)
        }
    }

    // MARK: - OpenCloseOperations & ReadWriteOperations

    public func openItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        if let orbitItem = item as? OrbitFSItem {
            drive.openFile(nodeID: orbitItem.nodeID)
        }
        reply(nil)
    }

    public func closeItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem else {
            reply(nil)
            return
        }
        Task {
            await drive.closeFile(nodeID: orbitItem.nodeID)
            reply(nil)
        }
    }

    public func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (Int, Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem, offset >= 0 else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        Task {
            do {
                let data = try await drive.readFile(
                    nodeID: orbitItem.nodeID,
                    offset: UInt64(offset),
                    length: length
                )
                let copied = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                    let count = min(data.count, rawBuf.count)
                    if count > 0, let base = rawBuf.baseAddress {
                        data.copyBytes(to: base.assumingMemoryBound(to: UInt8.self), count: count)
                    }
                    return count
                }
                reply(copied, nil)
            } catch {
                reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            }
        }
    }

    public func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping (Int, Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem, offset >= 0 else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        Task {
            do {
                let written = try await drive.writeFile(
                    nodeID: orbitItem.nodeID,
                    data: contents,
                    offset: UInt64(offset)
                )
                reply(written, nil)
            } catch {
                reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
            }
        }
    }

    // MARK: - XattrOperations

    public func getXattr(
        named name: FSFileName,
        of item: FSItem,
        replyHandler reply: @escaping (Data?, Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem,
              let attrName = name.string,
              let val = drive.xattrStore.get(nodeID: orbitItem.nodeID, name: attrName) else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOATTR)))
            return
        }
        reply(val, nil)
    }

    public func setXattr(
        named name: FSFileName,
        to value: Data?,
        on item: FSItem,
        policy: FSVolume.SetXattrPolicy,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem,
              let attrName = name.string else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        if policy == .delete {
            drive.xattrStore.set(nodeID: orbitItem.nodeID, name: attrName, value: nil)
        } else {
            drive.xattrStore.set(nodeID: orbitItem.nodeID, name: attrName, value: value)
        }
        reply(nil)
    }

    public func listXattrs(
        of item: FSItem,
        replyHandler reply: @escaping ([FSFileName]?, Error?) -> Void
    ) {
        guard let orbitItem = item as? OrbitFSItem else {
            reply([], nil)
            return
        }
        let names = drive.xattrStore.list(nodeID: orbitItem.nodeID).map { FSFileName(string: $0) }
        reply(names, nil)
    }
}

// MARK: - OrbitFileSystem (FSUnaryFileSystem + FSUnaryFileSystemOperations)

@available(macOS 15.4, *)
public final class OrbitFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    private var activeVolume: OrbitVolume?

    public func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void
    ) {
        let containerID = FSContainerIdentifier(uuid: UUID(uuidString: "4B9AD7AD-1329-3431-873F-874D0CE22A14")!)
        reply(FSProbeResult.usable(name: "Helumi", containerID: containerID), nil)
    }

    public func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, Error?) -> Void
    ) {
        var uid = getuid()
        var gid = getgid()
        let opts = options.taskOptions
        for (idx, opt) in opts.enumerated() {
            if opt == "-u", idx + 1 < opts.count, let parsed = UInt32(opts[idx + 1]) {
                uid = parsed
            } else if opt == "-g", idx + 1 < opts.count, let parsed = UInt32(opts[idx + 1]) {
                gid = parsed
            }
        }

        let api = OrbitAPI()
        let keyManager = KeyManager()
        let lockedRemote = LockedRemote(inner: api, keyManager: keyManager)
        let drive = OrbitDrive(remote: lockedRemote)

        let volID = FSVolume.Identifier(uuid: UUID(uuidString: "FFE5475D-3776-3AB8-9C0B-56A9EAC56D5E")!)
        let volume = OrbitVolume(
            volumeID: volID,
            volumeName: FSFileName(string: "Helumi"),
            drive: drive,
            ownerUID: uid,
            ownerGID: gid
        )
        self.activeVolume = volume
        reply(volume, nil)
    }

    public func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        activeVolume?.drive.saveTreeSnapshot()
        activeVolume = nil
        reply(nil)
    }
}

// Entrypoint
if CommandLine.arguments.contains("--self-test") {
    if #available(macOS 15.4, *) {
        let fs = OrbitFileSystem()
        print("OrbitFS native FSKit FSUnaryFileSystem initialized cleanly: \(fs)")
    }
    exit(0)
}

RunLoop.current.run()
