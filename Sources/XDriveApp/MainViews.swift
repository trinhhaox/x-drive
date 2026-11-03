import SwiftUI
import OrbitCore

// MARK: - MainWindowView

public struct MainWindowView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(AppModel.SidebarTab.allCases, selection: $model.selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(mountStatusLabel)
                            .font(.caption.weight(.medium))
                        Spacer()
                    }
                    Text("\(ByteCountFormatter.string(fromByteCount: quotaUsed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.quota.limitBytes, countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        } detail: {
            if !model.isSignedIn {
                SignInView(model: model)
            } else {
                Group {
                    switch model.selectedTab {
                    case .home:
                        HomeDashboardView(model: model)
                    case .search:
                        SpotlightSearchView(model: model)
                    case .privacy:
                        ZeroKnowledgePrivacyView(model: model)
                    case .settings:
                        DriveSettingsView(model: model)
                    case .feedback:
                        FeedbackView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $model.showWelcomeSheet) {
            WelcomeView(model: model)
        }
        .sheet(item: $model.activeApprovalSheetRequest) { req in
            AllowDeviceSheet(model: model, request: req)
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    private var quotaUsed: Int64 {
        model.quota.usedBytes + Int64(model.driveStatus.cacheBytes)
    }

    private var statusColor: Color {
        switch model.driveController.state {
        case .mounted: return .green
        case .mounting: return .orange
        default: return .secondary
        }
    }

    private var mountStatusLabel: String {
        switch model.driveController.state {
        case .mounted: return "Đã gắn /Volumes/Helumi"
        case .mounting: return "Đang gắn ổ đĩa..."
        default: return "Chưa gắn kết"
        }
    }
}

// MARK: - HomeDashboardView

public struct HomeDashboardView: View {
    @ObservedObject var model: AppModel

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header Banner
                HStack(spacing: 16) {
                    Image(systemName: "externaldrive.fill.badge.icloud")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("XDrive (OrbitFS)")
                                .font(.title2.bold())
                            if case .unlocked = model.privacyState {
                                Label("Zero-Knowledge E2EE", systemImage: "lock.shield.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                        Text("Ổ đĩa đám mây hiệu năng cao sử dụng Apple FSKit & bộ đệm khối 1 MiB")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.toggleFloatingSearchPanel()
                    } label: {
                        Label("Spotlight Panel", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.mountOrOpenDrive()
                    } label: {
                        Label("Mở trong Finder", systemImage: "folder.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(18)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))

                // GitHub Release Auto-Update Banner (appears automatically when a newer release tag exists)
                GitHubUpdateBannerView(updater: model.updater)

                // Drag & Drop File Upload Zone & Live Upload Lanes
                FileDropArea(model: model)
                UploadActivitySection(model: model)

                if let shareURL = model.lastCopiedShareURL {
                    HStack {
                        Image(systemName: "link.badge.plus")
                            .foregroundStyle(.green)
                        Text("Đã sao chép liên kết chia sẻ: \(shareURL)")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                // Storage & Cache Cards
                HStack(spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Dung lượng Đám mây (\(model.quota.plan))", systemImage: "icloud.fill")
                                .font(.headline)
                            ProgressView(value: Double(model.quota.usedBytes), total: Double(max(1, model.quota.limitBytes)))
                                .tint(.blue)
                            Text("\(ByteCountFormatter.string(fromByteCount: model.quota.usedBytes, countStyle: .file)) trên tổng \(ByteCountFormatter.string(fromByteCount: model.quota.limitBytes, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Bộ đệm Khối 1 MiB (ChunkStore)", systemImage: "internaldrive.fill")
                                .font(.headline)
                            HStack {
                                Text("Đang đệm: \(ByteCountFormatter.string(fromByteCount: Int64(model.driveStatus.cacheBytes), countStyle: .file))")
                                Spacer()
                                Text("Đã ghim: \(ByteCountFormatter.string(fromByteCount: Int64(model.driveStatus.pinnedBytes), countStyle: .file))")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if model.driveStatus.throttling {
                                Label("Đang tải lên nhẹ nhàng để giữ mạng mượt (Polite Uploads)", systemImage: "tortoise.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("Giới hạn tự động thu hồi khi đĩa đầy: \(Int(model.cacheLimitGB)) GB")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                    }
                }

                // Recent Uploads / Files in Virtual Tree
                GroupBox("Tệp trên Ổ đĩa Ảo (/Volumes/Helumi)") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.searchResults.prefix(10)) { item in
                            HStack {
                                Image(systemName: item.isDirectory ? "folder.fill" : "doc.text.fill")
                                    .foregroundStyle(item.isDirectory ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.body.weight(.medium))
                                    Text(item.relativePath)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !item.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    model.createShareLink(for: item)
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                                .help("Tạo liên kết chia sẻ (Kèm #sk=... nếu bật E2EE)")
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    .padding(8)
                }
            }
            .padding(24)
        }
    }
}

// MARK: - SpotlightSearchView

public struct SpotlightSearchView: View {
    @ObservedObject var model: AppModel

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Tìm kiếm tức thì toàn bộ tệp và thư mục trong DriveTree...", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onChange(of: model.searchQuery) { _, _ in
                        model.performSearch()
                    }
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                        model.performSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            List(model.searchResults) { node in
                HStack(spacing: 12) {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(node.isDirectory ? .blue : .secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(.body.weight(.medium))
                        Text(node.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !node.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(node.size), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
        .padding(24)
    }
}

// MARK: - ZeroKnowledgePrivacyView

public struct ZeroKnowledgePrivacyView: View {
    @ObservedObject var model: AppModel

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mã hóa Đầu cuối Zero-Knowledge (OrbitCore.ZK)")
                            .font(.title2.bold())
                        Text("Khóa chính 256-bit (HKDF-SHA256) • Mã hóa khối 1 MiB AES-GCM • Trao đổi khóa thiết bị P-256 ECDH")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                GroupBox("Trạng thái Mã hóa") {
                    VStack(alignment: .leading, spacing: 12) {
                        switch model.privacyState {
                        case .off:
                            Text("Hiện đang tắt E2EE. Khi bật, mọi tên tệp (`WireName: e1:...`) và từng khối dữ liệu 1 MiB (`ZK.piece = 1,048,576 B`) sẽ được mã hóa trên máy Mac trước khi tải lên.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Bật Mã hóa Đầu cuối Zero-Knowledge") {
                                model.enableZeroKnowledgeEncryption()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)

                        case .unlocked:
                            Label("Đã mở khóa Master Key — Toàn bộ tệp mới và hiện có đã được bảo vệ bằng AES-256-GCM.", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.headline)

                            if let code = model.generatedRecoveryCode ?? model.keyManager.recoveryCode() {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Mã Khôi phục Khẩn cấp (Recovery Code — 56 ký tự Base32 kèm HMAC Checksum):")
                                        .font(.caption.bold())
                                    Text(code)
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(10)
                                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }

                            HStack(spacing: 12) {
                                Button("Mô phỏng Yêu cầu Phê duyệt Thiết bị Mới (P-256 ECDH)") {
                                    model.simulateNewDeviceRequest()
                                }
                                Button("Khóa Phiên Tạm thời") {
                                    model.keyManager.lockSession()
                                    model.refreshSnapshot()
                                }
                            }

                        case .locked:
                            Label("Tài khoản đang khóa E2EE. Nhập Recovery Code hoặc phê duyệt từ thiết bị khác.", systemImage: "lock.fill")
                                .foregroundStyle(.orange)
                            HStack {
                                TextField("Nhập Recovery Code (XXXX-XXXX-...)", text: $model.unlockInputCode)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                Button("Mở khóa") {
                                    model.unlockWithRecoveryCode()
                                }
                                .buttonStyle(.borderedProminent)
                            }

                        case .migrating(let progress):
                            ProgressView("Đang mã hóa di trú tệp tin (PrivacySweep): \(progress.done)/\(progress.total)", value: Double(progress.done), total: Double(max(1, progress.total)))
                        }

                        if let err = model.errorMessage {
                            Text(err)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                    .padding(10)
                }

                if !model.pendingApprovals.isEmpty {
                    GroupBox("Phê duyệt Thiết bị Mới (ECDH P-256 Key Agreement)") {
                        ForEach(model.pendingApprovals) { req in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(req.deviceName)
                                        .font(.headline)
                                    Text("Mã đối chiếu 6 số (ZK.matchCode): ")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    + Text(model.simulatedMatchCode)
                                        .font(.system(.body, design: .monospaced).bold())
                                        .foregroundStyle(.blue)
                                }
                                Spacer()
                                Button("Chấp thuận & Cấp khóa") {
                                    model.approvePendingDevice(req)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(8)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - DriveSettingsView

public struct DriveSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    public init(model: AppModel) {
        self.model = model
        self.updater = model.updater
    }

    public var body: some View {
        Form {
            Section("Hệ thống Tệp Ảo FSKit & Bộ nhớ đệm (ChunkStore)") {
                HStack {
                    Text("Đường dẫn Mount:")
                    Spacer()
                    Text(MountHelper.mountPoint)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Giới hạn bộ đệm cục bộ: \(Int(model.cacheLimitGB)) GB")
                    Slider(value: $model.cacheLimitGB, in: 2...100, step: 2) { _ in
                        model.updateCacheLimit(model.cacheLimitGB)
                    }
                }
                HStack {
                    Text("Đã sử dụng: \(ByteCountFormatter.string(fromByteCount: Int64(model.driveStatus.cacheBytes), countStyle: .file))")
                    Spacer()
                    Button("Xóa bộ nhớ đệm (Trừ tệp đã ghim)") {
                        model.clearCache()
                    }
                }
            }

            Section("Điều tiết Băng thông Tải lên (PoliteUploads & UploadGovernor)") {
                Toggle("Tải lên lịch sự (Tự động giảm tốc khi phát hiện tăng RTT / Bufferbloat)", isOn: Binding(
                    get: { model.politeUploads },
                    set: { model.updatePoliteUploads($0) }
                ))
            }

            Section("Cập nhật Tự động từ GitHub Releases (trinhhaox/x-drive) & Tài khoản") {
                Toggle("Tự động kiểm tra bản phát hành mới trên GitHub khi khởi động", isOn: $updater.autoCheckEnabled)

                HStack {
                    Text(updater.statusMessage)
                        .font(.callout)
                    Spacer()
                    Button("Kiểm tra trên GitHub") {
                        Task {
                            await updater.checkForUpdates(silent: false)
                        }
                    }
                    .disabled(updater.isChecking || updater.isInstalling)
                }

                GitHubUpdateBannerView(updater: updater)

                HStack {
                    Button("Xem lại Hướng dẫn Onboarding") {
                        model.showWelcomeSheet = true
                    }
                    Spacer()
                    Button("Đăng xuất (\(model.user.email))") {
                        model.isSignedIn = false
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - MenuBarPanel (Status Bar Extra Menu)

public struct MenuBarPanel: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .foregroundStyle(.blue)
                Text("XDrive • \(model.quota.plan)")
                    .font(.headline)
                Spacer()
                if case .unlocked = model.privacyState {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                }
            }

            Divider()

            Text("Đã dùng: \(ByteCountFormatter.string(fromByteCount: model.quota.usedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.quota.limitBytes, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                model.mountOrOpenDrive()
            } label: {
                Label("Mở /Volumes/Helumi trong Finder", systemImage: "folder")
            }

            Button {
                if let code = model.keyManager.recoveryCode() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } else {
                    model.enableZeroKnowledgeEncryption()
                }
            } label: {
                Label(
                    model.privacyState == .off ? "Bật Mã hóa Zero-Knowledge E2EE" : "Sao chép Mã Khôi phục E2EE",
                    systemImage: "lock.shield"
                )
            }

            Divider()

            if let rel = model.updater.latestRelease {
                Button {
                    Task {
                        await model.updater.downloadAndInstallUpdate()
                    }
                } label: {
                    Label("Cập nhật XDrive v\(rel.version) từ GitHub", systemImage: "arrow.down.app.fill")
                }
            } else {
                Button {
                    Task {
                        await model.updater.checkForUpdates(silent: false)
                    }
                } label: {
                    Label("Kiểm tra Bản cập nhật trên GitHub", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Button("Thoát XDrive") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

