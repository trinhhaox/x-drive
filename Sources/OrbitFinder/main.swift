import Cocoa
import FinderSync
import OrbitCore

// MARK: - OrbitFinder (Finder Sync Extension: Badges & Context Menu)

public final class FinderSync: FIFinderSync {
    private let api = OrbitAPI()
    private let keyManager = KeyManager()
    private var statusTimer: Timer?

    public override init() {
        super.init()
        let mountURL = MountHelper.mountPointURL
        FIFinderSyncController.default().directoryURLs = [mountURL]
        registerBadges()
    }

    private func registerBadges() {
        let controller = FIFinderSyncController.default()
        if let upImg = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Uploading") {
            controller.setBadgeImage(upImg, label: "Đang tải lên", forBadgeIdentifier: "uploading")
        }
        if let syncImg = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Available on this Mac") {
            controller.setBadgeImage(syncImg, label: "Đã lưu trên máy Mac này", forBadgeIdentifier: "synced")
        }
        if let cloudImg = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "In the cloud") {
            controller.setBadgeImage(cloudImg, label: "Trên đám mây", forBadgeIdentifier: "cloud")
        }
        if let errImg = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Upload failed") {
            controller.setBadgeImage(errImg, label: "Lỗi tải lên", forBadgeIdentifier: "error")
        }
    }

    public override func requestBadgeIdentifier(for url: URL) {
        let tree = DriveTree()
        guard tree.load(from: SharedContainer.treeFile) else { return }
        let rel = url.path.replacingOccurrences(of: MountHelper.mountPoint, with: "")
        guard let node = tree.lookupPath(rel) else { return }

        let status = SharedContainer.readDriveStatus()
        let badgeID: String
        if status?.failedUploads.contains(where: { $0.id == node.id }) == true {
            badgeID = "error"
        } else if node.dirty || status?.uploadingFiles.contains(where: { $0.id == node.id }) == true {
            badgeID = "uploading"
        } else if let rem = node.remoteID,
                  (status?.pinnedRemoteIDs.contains(rem) == true || status?.cachedRemoteIDs.contains(rem) == true) {
            badgeID = "synced"
        } else {
            badgeID = "cloud"
        }
        FIFinderSyncController.default().setBadgeIdentifier(badgeID, for: url)
    }

    public override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }
        let menu = NSMenu(title: "XDrive")

        let shareItem = NSMenuItem(title: "Sao chép liên kết chia sẻ (Copy Share Link)", action: #selector(copyShareLink(_:)), keyEquivalent: "")
        shareItem.target = self
        menu.addItem(shareItem)

        let keepItem = NSMenuItem(title: "Giữ trên máy Mac này (Keep on This Mac)", action: #selector(toggleKeep(_:)), keyEquivalent: "")
        keepItem.target = self
        menu.addItem(keepItem)

        let stopShareItem = NSMenuItem(title: "Dừng chia sẻ (Stop Sharing)", action: #selector(stopSharing(_:)), keyEquivalent: "")
        stopShareItem.target = self
        menu.addItem(stopShareItem)

        let reqFilesItem = NSMenuItem(title: "Yêu cầu gửi tệp vào thư mục (Request Files...)", action: #selector(requestFiles(_:)), keyEquivalent: "")
        reqFilesItem.target = self
        menu.addItem(reqFilesItem)

        return menu
    }

    @objc public func copyShareLink(_ sender: AnyObject?) {
        guard let targetURL = FIFinderSyncController.default().targetedURL() ?? FIFinderSyncController.default().selectedItemURLs()?.first else {
            return
        }
        let tree = DriveTree()
        guard tree.load(from: SharedContainer.treeFile) else { return }
        let rel = targetURL.path.replacingOccurrences(of: MountHelper.mountPoint, with: "")
        guard let node = tree.lookupPath(rel), let remoteID = node.remoteID else { return }

        Task {
            if let share = try? await api.createShareLink(fileID: remoteID) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(share.url.absoluteString, forType: .string)
            }
        }
    }

    @objc public func toggleKeep(_ sender: AnyObject?) {
        guard let urls = FIFinderSyncController.default().selectedItemURLs() else { return }
        let tree = DriveTree()
        guard tree.load(from: SharedContainer.treeFile) else { return }
        let pinned = SharedContainer.readPinnedRemoteIDs()

        for url in urls {
            let rel = url.path.replacingOccurrences(of: MountHelper.mountPoint, with: "")
            if let node = tree.lookupPath(rel), let remID = node.remoteID {
                let isCurrentlyPinned = pinned.contains(remID)
                SharedContainer.setPinned(remoteID: remID, pinned: !isCurrentlyPinned)
                SharedContainer.requestDriveRefresh(remoteID: remID)
            }
        }
    }

    @objc public func stopSharing(_ sender: AnyObject?) {
        guard let urls = FIFinderSyncController.default().selectedItemURLs() else { return }
        let tree = DriveTree()
        guard tree.load(from: SharedContainer.treeFile) else { return }
        for url in urls {
            let rel = url.path.replacingOccurrences(of: MountHelper.mountPoint, with: "")
            if let node = tree.lookupPath(rel), let remID = node.remoteID {
                Task { try? await api.revokeShareLink(fileID: remID) }
            }
        }
    }

    @objc public func requestFiles(_ sender: AnyObject?) {
        guard let targetURL = FIFinderSyncController.default().targetedURL() ?? FIFinderSyncController.default().selectedItemURLs()?.first else {
            return
        }
        let tree = DriveTree()
        guard tree.load(from: SharedContainer.treeFile) else { return }
        let rel = targetURL.path.replacingOccurrences(of: MountHelper.mountPoint, with: "")
        guard let node = tree.lookupPath(rel), node.kind == .directory, let remID = node.remoteID else { return }

        Task {
            if let info = try? await api.createFileRequest(folderID: remID) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.url.absoluteString, forType: .string)
            }
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    let ext = FinderSync()
    print("OrbitFinder initialized: \(ext)")
    exit(0)
}

