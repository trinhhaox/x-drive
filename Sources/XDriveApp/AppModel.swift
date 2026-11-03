import SwiftUI
import OrbitCore

@MainActor
public final class AppModel: ObservableObject {
    public enum SidebarTab: String, CaseIterable, Identifiable {
        case home = "Trang chủ"
        case search = "Tìm kiếm"
        case privacy = "Bảo mật E2EE"
        case settings = "Cài đặt"
        case feedback = "Phản hồi"

        public var id: String { rawValue }
        public var icon: String {
            switch self {
            case .home: return "externaldrive.fill.badge.icloud"
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

    public init() {
        let locked = LockedRemote(inner: localBackend, keyManager: keyManager)
        self.lockedRemote = locked
        self.drive = OrbitDrive(remote: locked)
        let cacheSettings = SharedContainer.readCacheSettings()
        self.cacheLimitGB = Double(cacheSettings.limitBytes) / (1024 * 1024 * 1024)
        self.politeUploads = SharedContainer.readUploadSettings().polite

        CrashReports.shared.start()
        self.searchPanelController = SearchPanelController(appModel: self)
        self.ejectWatcher = EjectWatcher { [weak self] in
            self?.driveController.refreshState()
        }
        self.recentErrorReports = ErrorReporter.shared.latestReports()
        self.updater.startAutomaticChecks()

        Task {
            await bootstrapInitialFilesIfNeeded()
            refreshSnapshot()
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

    public func createShareLink(for node: SearchIndex.Node) {
        let baseShare = URL(string: "https://www.helumi.app/s/\(UUID().uuidString.prefix(10).lowercased())")!
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

    public func bootstrapInitialFilesIfNeeded() async {
        let rootChildren = (try? await drive.listDirectory(nodeID: DriveTree.rootID)) ?? []
        if rootChildren.isEmpty {
            let docs = try? await drive.createItem(name: "Tài liệu Dự án", parentID: DriveTree.rootID, kind: .directory)
            let media = try? await drive.createItem(name: "Thiết kế & Video", parentID: DriveTree.rootID, kind: .directory)
            let readmeNode = try? await drive.createItem(name: "Helumi-Architecture-Notes.md", parentID: DriveTree.rootID, kind: .file)
            if let rn = readmeNode {
                let sample = Data("# XDrive (OrbitFS + Zero-Knowledge E2EE)\nỔ đĩa đám mây tốc độ cao gắn tại /Volumes/Helumi.\n".utf8)
                _ = try? await drive.writeFile(nodeID: rn.id, data: sample, offset: 0)
                await drive.closeFile(nodeID: rn.id)
            }
            if let docs {
                let spec = try? await drive.createItem(name: "ZeroKnowledge-Protocol-Spec.pdf", parentID: docs.id, kind: .file)
                if let spec {
                    _ = try? await drive.writeFile(nodeID: spec.id, data: Data(repeating: 0x42, count: 64 * 1024), offset: 0)
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

    public func dropFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let created = try? await drive.createItem(
                    name: url.lastPathComponent,
                    parentID: DriveTree.rootID,
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
