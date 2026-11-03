import AppKit
import SwiftUI
import OrbitCore

@MainActor
public final class AppModel: ObservableObject {
    public enum SidebarTab: String, CaseIterable, Identifiable {
        case home = "Trang chủ"
        case files = "Quản lý Tệp"
        case search = "Tìm kiếm"
        case privacy = "Bảo mật E2EE"
        case settings = "Cài đặt"
        case feedback = "Phản hồi"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .home: return "externaldrive.fill.badge.icloud"
            case .files: return "folder.fill"
            case .search: return "magnifyingglass"
            case .privacy: return "lock.shield.fill"
            case .settings: return "gearshape.fill"
            case .feedback: return "bubble.left.and.exclamationmark.bubble.right.fill"
            }
        }
    }

    @Published public var selectedTab: SidebarTab = .home
    @Published public var showWelcomeSheet: Bool = false
    @Published public var isSignedIn: Bool = true
    @Published public var user: UserInfo = UserInfo(
        id: "usr_trinhhao",
        email: "mr.trinhhao@gmail.com",
        name: "Trịnh Hảo",
        plan: "Pro 2 TB",
        storageUsed: 14_580_000_000,
        storageLimit: 2_000_000_000_000
    )
    @Published public var quota: QuotaInfo = QuotaInfo(
        usedBytes: 14_580_000_000,
        limitBytes: 2_000_000_000_000,
        plan: "Pro 2 TB",
        fileCount: 128
    )
    @Published public var driveStatus: DriveStatusSnapshot = DriveStatusSnapshot()
    @Published public var privacyState: PrivacyState = .off
    @Published public var generatedRecoveryCode: String?
    @Published public var unlockInputCode: String = ""
    @Published public var errorMessage: String?
    @Published public var searchQuery: String = ""
    @Published public var searchResults: [SearchIndex.Node] = []
    @Published public var cacheLimitGB: Double = 10.0
    @Published public var politeUploads: Bool = true
    @Published public var pendingApprovals: [PendingDeviceApproval] = []
    @Published public var activeApprovalSheetRequest: PendingDeviceApproval?
    @Published public var simulatedMatchCode: String = "482 915"
    @Published public var lastCopiedShareURL: String?
    @Published public var recentErrorReports: [ErrorReportPayload] = []

    // Interactive File Explorer State
    @Published public var currentExplorerDirectoryID: UInt64 = DriveTree.rootID
    @Published public var explorerItems: [DriveNode] = []
    @Published public var explorerBreadcrumbs: [DriveNode] = []
    @Published public var pinnedRemoteIDs: Set<String> = []

    // Cloud Backend Endpoint State
    @Published public var apiEndpointURL: String = ProcessInfo.processInfo.environment["ORBIT_API_URL"] ?? "http://127.0.0.1:8787"
    @Published public var useLiveCloudflareBackend: Bool = false
    @Published public var backendConnectionStatus: String = "Đang dùng Bộ mô phỏng Đám mây Cục bộ (LocalWireRemote)"

    public let localBackend = LocalWireRemote()
    public let keyManager = KeyManager(
        localStore: InMemorySecretStore(),
        cloudStore: InMemorySecretStore()
    )
    public let lockedRemote: LockedRemote
    public let drive: OrbitDrive
    public let driveController = DriveController()
    public let searchIndex = SearchIndex()
    public let browserSignIn = BrowserSignIn()
    public let updater = Updater()
    public let deviceNotifier = DeviceNotifier()
    public private(set) var searchPanelController: SearchPanelController?
    private var ejectWatcher: EjectWatcher?
    private var keyMonitor: Any?

    public init() {
        let locked = LockedRemote(inner: localBackend, keyManager: keyManager)
        self.lockedRemote = locked
        self.drive = OrbitDrive(remote: locked)
        let cacheSettings = SharedContainer.readCacheSettings()
        self.cacheLimitGB = Double(cacheSettings.limitBytes) / (1024 * 1024 * 1024)
        self.politeUploads = SharedContainer.readUploadSettings().polite
        self.pinnedRemoteIDs = SharedContainer.readPinnedRemoteIDs()

        CrashReports.shared.start()
        self.searchPanelController = SearchPanelController(appModel: self)
        self.ejectWatcher = EjectWatcher { [weak self] in
            self?.driveController.refreshState()
        }
        self.recentErrorReports = ErrorReporter.shared.latestReports()
        self.updater.startAutomaticChecks()
        registerKeyboardShortcut()

        Task {
            await bootstrapInitialFilesIfNeeded()
            refreshSnapshot()
        }
    }

    private func registerKeyboardShortcut() {
        // Shortcut: Command + Shift + K toggles Floating Spotlight Panel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "k" {
                Task { @MainActor in
                    self?.toggleFloatingSearchPanel()
                }
                return nil
            }
            return event
        }
    }

    public func completeWelcomeOnboarding() {
        showWelcomeSheet = false
    }

    public func signInWithCredentials(email: String) {
        user = UserInfo(
            id: "usr_\(email.prefix(8))",
            email: email,
            name: email.components(separatedBy: "@").first?.capitalized ?? "User",
            plan: "Pro 2 TB",
            storageUsed: quota.usedBytes,
            storageLimit: quota.limitBytes
        )
        isSignedIn = true
    }

    public func refreshErrorReports() {
        recentErrorReports = ErrorReporter.shared.latestReports()
    }

    public func toggleFloatingSearchPanel() {
        searchPanelController?.togglePanel()
    }

    // MARK: - Explorer Navigation & File Actions

    public func navigateExplorer(to directoryID: UInt64) {
        currentExplorerDirectoryID = directoryID
        Task {
            _ = try? await drive.listDirectory(nodeID: directoryID)
            rebuildExplorerState()
        }
    }

    public func refreshCurrentExplorerDirectory() {
        Task {
            try? await drive.refreshDirectory(nodeID: currentExplorerDirectoryID)
            SharedContainer.requestDriveRefresh(remoteID: drive.tree.node(id: currentExplorerDirectoryID)?.remoteID)
            refreshSnapshot()
        }
    }

    public func rebuildExplorerState() {
        explorerItems = drive.tree.listChildren(of: currentExplorerDirectoryID)
        var crumbs: [DriveNode] = []
        var cursor: UInt64? = currentExplorerDirectoryID
        var visited = Set<UInt64>()
        while let cid = cursor, !visited.contains(cid), let node = drive.tree.node(id: cid) {
            visited.insert(cid)
            crumbs.insert(node, at: 0)
            if cid == DriveTree.rootID { break }
            cursor = node.parentID
        }
        explorerBreadcrumbs = crumbs
    }

    public func createExplorerFolder(name: String) {
        Task {
            _ = try? await drive.createItem(name: name, parentID: currentExplorerDirectoryID, kind: .directory)
            refreshSnapshot()
        }
    }

    public func renameExplorerNode(_ node: DriveNode, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            _ = try? await drive.renameItem(nodeID: node.id, newParentID: node.parentID, newName: trimmed)
            refreshSnapshot()
        }
    }

    public func deleteExplorerNode(_ node: DriveNode) {
        Task {
            try? await drive.removeItem(nodeID: node.id)
            refreshSnapshot()
        }
    }

    public func isNodePinned(_ node: DriveNode) -> Bool {
        guard let remID = node.remoteID else { return false }
        return pinnedRemoteIDs.contains(remID)
    }

    public func togglePinNode(_ node: DriveNode) {
        guard let remID = node.remoteID else { return }
        let nowPinned: Bool
        if pinnedRemoteIDs.contains(remID) {
            pinnedRemoteIDs.remove(remID)
            nowPinned = false
        } else {
            pinnedRemoteIDs.insert(remID)
            nowPinned = true
            // Prefetch file into ChunkStore so it stays offline-ready
            Task {
                _ = try? await drive.readFile(nodeID: node.id, offset: 0, length: Int(min(node.size, UInt64(ZK.piece))))
                refreshSnapshot()
            }
        }
        SharedContainer.setPinned(remoteID: remID, pinned: nowPinned)
        drive.chunkStore.setPinnedRemoteIDs(pinnedRemoteIDs)
        refreshSnapshot()
    }

    public func createShareLinkForDriveNode(_ node: DriveNode) {
        let searchNode = SearchIndex.Node(
            id: node.id,
            name: node.name,
            relativePath: drive.tree.relativePath(of: node.id) ?? "/\(node.name)",
            isDirectory: node.kind == .directory,
            size: node.size,
            modifiedAt: node.modifiedAt
        )
        createShareLink(for: searchNode)
    }

    public func createFileRequestForCurrentFolder() -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let base = apiEndpointURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = "\(base)/r/\(token)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        return url
    }

    public func createShareLink(for node: SearchIndex.Node) {
        let base = apiEndpointURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let baseShare = URL(string: "\(base)/s/\(UUID().uuidString.prefix(10).lowercased())")!
        if let keys = keyManager.keys {
            let secrets = ZK.newFileSecrets()
            if let pkg = try? ShareMaker.makeEncryptedShareURL(
                baseShareURL: baseShare,
                secrets: secrets,
                fileName: node.name,
                accountKeys: keys
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pkg.fullShareURL.absoluteString, forType: .string)
                lastCopiedShareURL = pkg.fullShareURL.absoluteString
                return
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseShare.absoluteString, forType: .string)
        lastCopiedShareURL = baseShare.absoluteString
    }

    public func testCloudflareBackendConnection() {
        guard let url = URL(string: apiEndpointURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/app/appcast.xml") else {
            backendConnectionStatus = "URL không hợp lệ."
            return
        }
        backendConnectionStatus = "Đang kiểm tra kết nối tới \(url.host ?? apiEndpointURL)..."
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                    backendConnectionStatus = "Kết nối Cloudflare Worker thành công (HTTP \(http.statusCode))!"
                } else {
                    backendConnectionStatus = "Không nhận được phản hồi hợp lệ từ Worker."
                }
            } catch {
                backendConnectionStatus = "Chưa kết nối được Worker (\(error.localizedDescription)) — Đang dùng LocalWireRemote."
            }
        }
    }

    public func bootstrapInitialFilesIfNeeded() async {
        let rootChildren = (try? await drive.listDirectory(nodeID: DriveTree.rootID)) ?? []
        if rootChildren.isEmpty {
            let docs = try? await drive.createItem(name: "Tài liệu Dự án", parentID: DriveTree.rootID, kind: .directory)
            let media = try? await drive.createItem(name: "Thiết kế & Video", parentID: DriveTree.rootID, kind: .directory)
            let readmeNode = try? await drive.createItem(name: "Helumi-Architecture-Notes.md", parentID: DriveTree.rootID, kind: .file)
            if let rn = readmeNode {
                let sample = Data("# XDrive (OrbitFS + Zero-Knowledge E2EE)\nỔ đĩa đám mây tốc độ cao gắn tại /Volumes/Helumi.\n- Khối dữ liệu chuẩn: 1 MiB (1,048,576 bytes)\n- Mã hóa đầu cuối: AES-256-GCM + HKDF-SHA256 + P-256 ECDH\n".utf8)
                _ = try? await drive.writeFile(nodeID: rn.id, data: sample, offset: 0)
                await drive.closeFile(nodeID: rn.id)
            }
            if let docs {
                let spec = try? await drive.createItem(name: "ZeroKnowledge-Protocol-Spec.pdf", parentID: docs.id, kind: .file)
                if let spec {
                    _ = try? await drive.writeFile(nodeID: spec.id, data: Data("PDF-1.7 Zero-Knowledge Specification Document\n".utf8), offset: 0)
                    await drive.closeFile(nodeID: spec.id)
                }
            }
            if let media {
                let vid = try? await drive.createItem(name: "Demo-4K-Render.mov", parentID: media.id, kind: .file)
                if let vid {
                    _ = try? await drive.writeFile(nodeID: vid.id, data: Data(repeating: 0x5A, count: 256 * 1024), offset: 0)
                    await drive.closeFile(nodeID: vid.id)
                }
            }
        }
        searchIndex.rebuild(from: drive.tree)
        performSearch()
        refreshSnapshot()
    }

    public func refreshSnapshot() {
        driveStatus = drive.currentStatusSnapshot()
        privacyState = keyManager.state
        searchIndex.rebuild(from: drive.tree)
        performSearch()
        rebuildExplorerState()
        refreshErrorReports()
    }

    public func performSearch() {
        searchResults = searchIndex.search(query: searchQuery, limit: 50)
    }

    public func mountOrOpenDrive() {
        Task {
            await driveController.mountDrive()
            if case .mounted(let url) = driveController.state {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func dropFiles(_ urls: [URL], intoParentID parentID: UInt64 = DriveTree.rootID) {
        Task {
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let created = try? await drive.createItem(
                    name: url.lastPathComponent,
                    parentID: parentID,
                    kind: .file
                )
                if let created {
                    _ = try? await drive.writeFile(nodeID: created.id, data: data, offset: 0)
                    await drive.closeFile(nodeID: created.id)
                }
            }
            refreshSnapshot()
        }
    }

    // MARK: - Zero-Knowledge E2EE Actions

    public func enableZeroKnowledgeEncryption() {
        do {
            let res = try keyManager.setupNewMasterKey(for: user.id)
            generatedRecoveryCode = res.recoveryCode
            privacyState = keyManager.state

            Task { [weak self] in
                guard let self else { return }
                let sweep = PrivacySweep(remote: self.localBackend, keyManager: self.keyManager)
                _ = try? await sweep.runSweep { [weak self] prog in
                    Task { @MainActor in
                        self?.privacyState = .migrating(prog)
                    }
                }
                self.refreshSnapshot()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func unlockWithRecoveryCode() {
        do {
            _ = try keyManager.unlock(recoveryCode: unlockInputCode, expectedKeyCheck: nil)
            unlockInputCode = ""
            errorMessage = nil
            refreshSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func simulateNewDeviceRequest() {
        let devPriv = ZK.newDeviceKeyPair()
        let pubB64 = ZK.base64URLEncode(devPriv.publicKey.x963Representation)
        let reqID = "dev_\(UUID().uuidString.prefix(8))"
        simulatedMatchCode = ZK.matchCode(deviceID: reqID, publicKey: pubB64)
        let request = PendingDeviceApproval(
            id: reqID,
            deviceName: "MacBook Pro 16-inch (M4 Max)",
            publicKey: pubB64,
            createdAt: Int64(Date().timeIntervalSince1970),
            expiresAt: Int64(Date().addingTimeInterval(600).timeIntervalSince1970)
        )
        pendingApprovals = [request]
        activeApprovalSheetRequest = request
        deviceNotifier.presentApprovalSheet(for: request)
    }

    public func approvePendingDevice(_ item: PendingDeviceApproval) {
        guard let master = keyManager.masterKey else { return }
        _ = try? ZK.grantForDevice(master: master, peerPublic: item.publicKey, deviceID: item.id)
        pendingApprovals.removeAll { $0.id == item.id }
        if activeApprovalSheetRequest?.id == item.id {
            activeApprovalSheetRequest = nil
        }
        deviceNotifier.dismiss()
    }

    public func rejectPendingDevice(_ item: PendingDeviceApproval) {
        pendingApprovals.removeAll { $0.id == item.id }
        if activeApprovalSheetRequest?.id == item.id {
            activeApprovalSheetRequest = nil
        }
        deviceNotifier.dismiss()
    }

    public func clearCache() {
        drive.chunkStore.clearAll(includePinned: false)
        refreshSnapshot()
    }

    public func updateCacheLimit(_ gb: Double) {
        cacheLimitGB = gb
        let bytes = UInt64(gb * 1024 * 1024 * 1024)
        SharedContainer.writeCacheSettings(CacheSettings(limitBytes: bytes))
        drive.chunkStore.setLimits(ChunkStore.Limits(maxBytes: bytes))
        refreshSnapshot()
    }

    public func updatePoliteUploads(_ enabled: Bool) {
        politeUploads = enabled
        SharedContainer.writeUploadSettings(UploadSettings(polite: enabled))
        drive.governor.setPoliteEnabled(enabled)
        refreshSnapshot()
    }
}
