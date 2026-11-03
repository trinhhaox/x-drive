import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
    @Published public var showPlanPickerSheet: Bool = false
    @Published public var customGigabytesInput: Int = 100
    @Published public var isSignedIn: Bool = true
    @Published public var user: UserInfo = UserInfo(
        id: "usr_trinhhao",
        email: "mr.trinhhao@gmail.com",
        name: "Trịnh Hảo",
        plan: "Cloudflare R2 (10 GB Miễn phí)",
        storageUsed: 0,
        storageLimit: 10_737_418_240
    )
    @Published public var quota: QuotaInfo = QuotaInfo(
        usedBytes: 0,
        limitBytes: 10_737_418_240,
        plan: "Cloudflare R2 (10 GB Miễn phí)",
        fileCount: 0
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

    // Cloud Backend Endpoint & Multi-Cloud Provider State
    @Published public var apiEndpointURL: String = ProcessInfo.processInfo.environment["ORBIT_API_URL"] ?? "https://xdrive-orbit-api.mr-trinhhao.workers.dev"
    @Published public var selectedStorageProvider: MultiCloudProviderType = .cloudflare
    @Published public var backendConnectionStatus: String = "Đã kết nối Cloudflare Workers (https://xdrive-orbit-api.mr-trinhhao.workers.dev)"
    @Published public var googleDriveAccessToken: String = ""
    @Published public var googleDriveUserEmail: String = ""
    @Published public var googleDriveStatus: String = "Sẵn sàng (Mô phỏng Google Drive API v3)"
    @Published public var showCloudflareGuide: Bool = false
    @Published public var showGoogleDriveGuide: Bool = false

    // Storage Optimization & MacBook SSD Health
    @Published public var isClearingCache: Bool = false
    @Published public var cacheCleanNotification: String? = nil
    @Published public var physicalBundleSizeBytes: UInt64 = 0

    public let multiCloudProxy: MultiCloudProxyRemote
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
        let endpointURL = URL(string: ProcessInfo.processInfo.environment["ORBIT_API_URL"] ?? "https://xdrive-orbit-api.mr-trinhhao.workers.dev")
        let proxy = MultiCloudProxyRemote(
            initialProvider: .cloudflare,
            cloudflareBackend: OrbitAPI(baseURL: endpointURL),
            googleDriveBackend: GoogleDriveRemote()
        )
        self.multiCloudProxy = proxy
        let locked = LockedRemote(inner: proxy, keyManager: keyManager)
        self.lockedRemote = locked
        self.drive = OrbitDrive(remote: locked)

        let savedToken = UserDefaults.standard.string(forKey: "GoogleDriveAccessToken") ?? ""
        let savedEmail = UserDefaults.standard.string(forKey: "GoogleDriveUserEmail") ?? ""
        self.googleDriveAccessToken = savedToken
        self.googleDriveUserEmail = savedEmail
        if !savedToken.isEmpty {
            let creds = GoogleDriveCredentials(
                accessToken: savedToken,
                userEmail: savedEmail.isEmpty ? nil : savedEmail
            )
            proxy.googleDriveBackend.updateCredentials(creds)
        }

        let savedProviderRaw = UserDefaults.standard.string(forKey: "SelectedStorageProvider")
        let initialProvider: MultiCloudProviderType = {
            if let raw = savedProviderRaw, let match = MultiCloudProviderType(rawValue: raw) {
                return match
            }
            return !savedToken.isEmpty ? .googleDrive : .cloudflare
        }()
        self.selectedStorageProvider = initialProvider
        proxy.setProvider(initialProvider)
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
        setupLiveVolumeWatcher()

        Task {
            await bootstrapInitialFilesIfNeeded()
            if self.selectedStorageProvider == .googleDrive {
                await refreshGoogleDriveQuotaAndUser()
            } else {
                await refreshCloudflareQuotaAndUser()
            }
            await driveController.mountDrive()
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
        if let ghost = drive.tree.lookup(name: "501", inParent: DriveTree.rootID) {
            _ = drive.tree.remove(id: ghost.id)
        }
        explorerItems = drive.tree.listChildren(of: currentExplorerDirectoryID)
            .filter { !$0.name.hasPrefix(".") && $0.name != "501" && $0.name != ".Trashes" }
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
        guard let url = URL(string: apiEndpointURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/health") else {
            backendConnectionStatus = "URL không hợp lệ."
            return
        }
        backendConnectionStatus = "Đang kiểm tra kết nối tới \(url.host ?? apiEndpointURL)..."
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(from: url)
                if let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                    backendConnectionStatus = "Kết nối Cloudflare Worker thành công (HTTP \(http.statusCode))!"
                    await refreshCloudflareQuotaAndUser()
                } else {
                    backendConnectionStatus = "Không nhận được phản hồi hợp lệ từ Worker."
                }
            } catch {
                backendConnectionStatus = "Chưa kết nối được Worker (\(error.localizedDescription))."
            }
        }
    }

    public func bootstrapInitialFilesIfNeeded() async {
        let rootChildren = (try? await drive.listDirectory(nodeID: DriveTree.rootID)) ?? []
        if rootChildren.isEmpty {
            let docs = try? await drive.createItem(name: "Tài liệu Dự án", parentID: DriveTree.rootID, kind: .directory)
            let media = try? await drive.createItem(name: "Thiết kế & Video", parentID: DriveTree.rootID, kind: .directory)
            let readmeNode = try? await drive.createItem(name: "XDrive-Architecture-Notes.md", parentID: DriveTree.rootID, kind: .file)
            if let rn = readmeNode {
                let sample = Data("# XDrive (OrbitFS + Zero-Knowledge E2EE)\nỔ đĩa đám mây tốc độ cao gắn tại /Volumes/XDrive.\n- Khối dữ liệu chuẩn: 1 MiB (1,048,576 bytes)\n- Mã hóa đầu cuối: AES-256-GCM + HKDF-SHA256 + P-256 ECDH\n".utf8)
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
        updateQuotaFromLocalTree()
        physicalBundleSizeBytes = LiveVolumeManager.shared.physicalBundleSizeBytes()
    }

    public func performSearch() {
        searchResults = searchIndex.search(query: searchQuery, limit: 50)
    }

    public func mountOrOpenDrive() {
        let mountURL = LiveVolumeManager.mountPointURL
        NSApp.activate(ignoringOtherApps: true)
        if FileManager.default.fileExists(atPath: mountURL.path) {
            NSWorkspace.shared.open(mountURL)
        } else {
            Task {
                await LiveVolumeManager.shared.mountLiveVolume()
                NSWorkspace.shared.open(mountURL)
            }
        }
    }

    public func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = AppDelegate.shared?.mainWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        for window in NSApp.windows where !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    // MARK: - Live Volume Two-Way Sync (FSEvents & Disk Mirroring)

    private func setupLiveVolumeWatcher() {
        LiveVolumeManager.shared.onFileChanged = { [weak self] urls in
            guard let self else { return }
            Task { @MainActor in
                await self.handleLiveDiskFilesChanged(urls)
            }
        }
    }

    public func handleLiveDiskFilesChanged(_ urls: [URL]) async {
        for url in urls {
            let name = url.lastPathComponent
            let fullPath = url.path
            // Ignore system metadata and user trash folders (.Trashes/501, .fseventsd, etc.)
            if name.hasPrefix(".") || name == "501" || fullPath.contains("/.Trashes") || fullPath.contains("/.fseventsd") {
                continue
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    let children = (try? await drive.listDirectory(nodeID: DriveTree.rootID)) ?? []
                    if !children.contains(where: { $0.name == name && $0.kind == .directory }) {
                        _ = try? await drive.createItem(name: name, parentID: DriveTree.rootID, kind: .directory)
                    }
                } else {
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let children = (try? await drive.listDirectory(nodeID: DriveTree.rootID)) ?? []
                    if let existing = children.first(where: { $0.name == name && $0.kind == .file }) {
                        _ = try? await drive.writeFile(nodeID: existing.id, data: data, offset: 0)
                        await drive.closeFile(nodeID: existing.id)
                    } else {
                        if let created = try? await drive.createItem(name: name, parentID: DriveTree.rootID, kind: .file) {
                            _ = try? await drive.writeFile(nodeID: created.id, data: data, offset: 0)
                            await drive.closeFile(nodeID: created.id)
                        }
                    }
                }
            }
        }
        refreshSnapshot()
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
                // Mirror out to real mounted volume on /Volumes/XDrive
                LiveVolumeManager.shared.mirrorFileToLiveDisk(relativePath: url.lastPathComponent, data: data)
            }
            refreshSnapshot()
        }
    }

    public func handleDroppedItemProviders(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let self else { return }
                var fileURL: URL?
                if let url = item as? URL {
                    fileURL = url
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    fileURL = url
                }
                guard let target = fileURL else { return }
                Task { @MainActor in
                    self.dropFilesAndShare([target])
                }
            }
        }
    }

    public func dropFilesAndShare(_ urls: [URL]) {
        dropFiles(urls)
        if let first = urls.first {
            let node = SearchIndex.Node(
                id: UInt64(abs(first.lastPathComponent.hashValue)),
                name: first.lastPathComponent,
                relativePath: "/\(first.lastPathComponent)",
                isDirectory: false,
                size: 0,
                modifiedAt: Date()
            )
            createShareLink(for: node)
        }
    }

    // MARK: - Multi-Cloud Provider Management (Cloudflare & Google Drive)

    public func switchStorageProvider(to provider: MultiCloudProviderType) {
        selectedStorageProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "SelectedStorageProvider")
        multiCloudProxy.setProvider(provider)
        Task {
            switch provider {
            case .cloudflare:
                backendConnectionStatus = "Đã chuyển sang Cloudflare Workers (OrbitAPI)"
                testCloudflareBackendConnection()
                await refreshCloudflareQuotaAndUser()
            case .googleDrive:
                backendConnectionStatus = "Đã chuyển sang Google Drive (Google API v3)"
                await refreshGoogleDriveQuotaAndUser()
            }
            refreshSnapshot()
        }
    }

    public func connectGoogleDrive(accessToken: String, email: String? = nil) {
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        googleDriveAccessToken = trimmed
        if let email, !email.isEmpty { googleDriveUserEmail = email }

        UserDefaults.standard.set(trimmed, forKey: "GoogleDriveAccessToken")
        if !googleDriveUserEmail.isEmpty {
            UserDefaults.standard.set(googleDriveUserEmail, forKey: "GoogleDriveUserEmail")
        }

        let creds = GoogleDriveCredentials(
            accessToken: trimmed,
            userEmail: googleDriveUserEmail.isEmpty ? nil : googleDriveUserEmail
        )
        multiCloudProxy.googleDriveBackend.updateCredentials(creds)
        switchStorageProvider(to: .googleDrive)
    }

    public func disconnectGoogleDrive() {
        googleDriveAccessToken = ""
        googleDriveUserEmail = ""
        googleDriveStatus = "Đã ngắt kết nối Google Drive"
        UserDefaults.standard.removeObject(forKey: "GoogleDriveAccessToken")
        UserDefaults.standard.removeObject(forKey: "GoogleDriveUserEmail")
        multiCloudProxy.googleDriveBackend.updateCredentials(nil)
        switchStorageProvider(to: .cloudflare)
    }

    public func refreshGoogleDriveQuotaAndUser() async {
        do {
            let (usr, q) = try await multiCloudProxy.googleDriveBackend.fetchAboutAndQuota()
            self.user = usr
            self.quota = q
            self.googleDriveStatus = "Kết nối Google Drive thành công (\(usr.email))"
        } catch {
            self.googleDriveStatus = "Lỗi kết nối Google Drive: \(error.localizedDescription)"
        }
    }

    public func refreshCloudflareQuotaAndUser() async {
        do {
            let u = try await multiCloudProxy.cloudflareBackend.me()
            let q = try await multiCloudProxy.cloudflareBackend.quota()
            await MainActor.run {
                self.user = u
                self.quota = q
                self.updateQuotaFromLocalTree()
            }
        } catch {
            await MainActor.run {
                self.updateQuotaFromLocalTree()
            }
        }
    }

    public func updateQuotaFromLocalTree() {
        let allNodes = drive.tree.allNodesSnapshot()
        let fileNodes = allNodes.filter { $0.kind == .file }
        let totalBytes = fileNodes.reduce(Int64(0)) { $0 + Int64($1.size) }
        let count = fileNodes.count
        let finalUsed = max(self.quota.usedBytes, totalBytes)
        let finalCount = max(self.quota.fileCount, count)
        self.quota = QuotaInfo(
            usedBytes: finalUsed,
            limitBytes: self.quota.limitBytes > 0 ? self.quota.limitBytes : 10_737_418_240,
            plan: self.quota.plan.isEmpty ? "Cloudflare R2 (10 GB Miễn phí)" : self.quota.plan,
            fileCount: finalCount
        )
        self.user.storageUsed = finalUsed
    }

    public func applyStoragePlan(tier: StorageTier) {
        let planTitle = tier.isFree ? "\(tier.name)" : "\(tier.name) (~$\(String(format: "%.2f", tier.priceUSDMonthly))/tháng)"
        self.quota = QuotaInfo(
            usedBytes: self.quota.usedBytes,
            limitBytes: tier.limitBytes,
            plan: planTitle,
            fileCount: self.quota.fileCount
        )
        self.user.plan = planTitle
        self.user.storageLimit = tier.limitBytes

        Task {
            if selectedStorageProvider == .cloudflare {
                try? await multiCloudProxy.cloudflareBackend.updatePlan(
                    limitBytes: tier.limitBytes,
                    planName: planTitle
                )
            }
            refreshSnapshot()
        }
    }

    public func applyCustomStoragePlan(gigabytes: Int) {
        let tier = StorageTier.customTier(gigabytes: max(1, gigabytes))
        applyStoragePlan(tier: tier)
    }

    // MARK: - Zero-Knowledge E2EE Actions

    public func enableZeroKnowledgeEncryption() {
        do {
            let res = try keyManager.setupNewMasterKey(for: user.id)
            generatedRecoveryCode = res.recoveryCode
            privacyState = keyManager.state

            Task { [weak self] in
                guard let self else { return }
                let sweep = PrivacySweep(remote: self.multiCloudProxy, keyManager: self.keyManager)
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

    /// Complete SSD Optimization: Clears unpinned local cache chunks & runs `hdiutil compact` to reclaim Mac SSD host space
    public func clearMacCacheAndOptimizeStorage() {
        guard !isClearingCache else { return }
        isClearingCache = true
        let oldChunkBytes = drive.chunkStore.totalBytes
        let oldBundleBytes = LiveVolumeManager.shared.physicalBundleSizeBytes()

        Task {
            // 1. Evict unpinned chunks in memory & cache dir
            drive.chunkStore.clearAll(includePinned: false)

            // 2. Run hdiutil compact to reclaim disk space from XDriveVolume.sparsebundle
            _ = await LiveVolumeManager.shared.compactSparseBundle()

            let newChunkBytes = drive.chunkStore.totalBytes
            let newBundleBytes = LiveVolumeManager.shared.physicalBundleSizeBytes()

            let freedChunks = oldChunkBytes > newChunkBytes ? oldChunkBytes - newChunkBytes : 0
            let freedBundle = oldBundleBytes > newBundleBytes ? oldBundleBytes - newBundleBytes : 0
            let totalFreed = max(freedChunks + freedBundle, oldChunkBytes)
            let freedStr = ByteCountFormatter.string(fromByteCount: Int64(totalFreed), countStyle: .file)

            await MainActor.run {
                self.isClearingCache = false
                self.cacheCleanNotification = "Đã dọn dẹp và giải phóng \(freedStr) dung lượng SSD Mac!"
                self.refreshSnapshot()
            }

            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if self.cacheCleanNotification?.contains(freedStr) == true {
                    self.cacheCleanNotification = nil
                }
            }
        }
    }

    /// Evicts cached chunks for a specific file node to make it online-only (0 Byte on Mac)
    public func evictNodeChunks(_ node: DriveNode) {
        guard let remID = node.remoteID else { return }
        if pinnedRemoteIDs.contains(remID) {
            togglePinNode(node)
        }
        drive.chunkStore.invalidate(remoteID: remID)
        refreshSnapshot()
        cacheCleanNotification = "Đã đưa '\(node.name)' về trạng thái Chỉ trên Đám mây (0 Byte trên SSD Mac)."
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if self.cacheCleanNotification?.contains(node.name) == true {
                    self.cacheCleanNotification = nil
                }
            }
        }
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
