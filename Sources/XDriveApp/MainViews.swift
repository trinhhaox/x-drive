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
                    case .files:
                        DriveExplorerView(model: model)
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
        .sheet(isPresented: $model.showPlanPickerSheet) {
            StoragePlanSheet(model: model)
        }
        .sheet(item: $model.activeApprovalSheetRequest) { req in
            AllowDeviceSheet(model: model, request: req)
        }
        .frame(minWidth: 780, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 6) {
                    Text("Lưu trữ:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $model.selectedStorageProvider) {
                        Label("Cloudflare R2", systemImage: "cloud.fill").tag(MultiCloudProviderType.cloudflare)
                        Label("Google Drive", systemImage: "externaldrive.fill.badge.icloud").tag(MultiCloudProviderType.googleDrive)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .onChange(of: model.selectedStorageProvider) { _, newP in
                        model.switchStorageProvider(to: newP)
                    }
                }
            }
        }
    }

    private var quotaUsed: Int64 {
        max(model.quota.usedBytes, Int64(model.driveStatus.cacheBytes))
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
        case .mounted: return "Đã gắn /Volumes/XDrive"
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

                // Multi-Cloud Provider Switcher Bar (Quick toggle between Cloudflare & Google Drive)
                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: model.selectedStorageProvider == .cloudflare ? "cloud.fill" : "externaldrive.fill.badge.icloud")
                            .font(.title2)
                            .foregroundStyle(model.selectedStorageProvider == .cloudflare ? .orange : .blue)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Đám Mây Đang Hoạt Động:")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(model.selectedStorageProvider == .cloudflare ? "Cloudflare R2" : "Google Drive")
                                    .font(.caption.bold())
                                    .foregroundStyle(model.selectedStorageProvider == .cloudflare ? .orange : .blue)
                            }
                            Text(model.selectedStorageProvider == .cloudflare ? "Mã hóa Zero-Knowledge • Egress 0đ • \(model.quota.plan)" : "Google API v3 • \(model.user.email) • \(model.quota.plan)")
                                .font(.callout.weight(.medium))
                        }

                        Spacer()

                        Picker("Chuyển đổi Đám mây:", selection: $model.selectedStorageProvider) {
                            Label("Cloudflare R2", systemImage: "cloud.fill").tag(MultiCloudProviderType.cloudflare)
                            Label("Google Drive", systemImage: "externaldrive.fill.badge.icloud").tag(MultiCloudProviderType.googleDrive)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                        .onChange(of: model.selectedStorageProvider) { _, newP in
                            model.switchStorageProvider(to: newP)
                        }
                    }
                    .padding(4)
                }

                // MacBook SSD Storage Saver Card (Zero-Footprint Optimization)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "bolt.shield.fill")
                                .font(.title)
                                .foregroundStyle(.green)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text("Bảo Vệ & Tối Ưu Hóa Ổ Cứng MacBook")
                                        .font(.headline)
                                    Text("Zero SSD Footprint")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                                Text("Toàn bộ tệp nằm 100% trên đám mây. MacBook chỉ lưu tệp biểu kiến ảo và stream dữ liệu 1 MiB khi mở.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                model.clearMacCacheAndOptimizeStorage()
                            } label: {
                                if model.isClearingCache {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.trailing, 4)
                                    Text("Đang dọn dẹp SSD...")
                                } else {
                                    Label("Giải phóng SSD ngay", systemImage: "sparkles")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(model.isClearingCache)
                        }

                        Divider()

                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Dung lượng trên Mây")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: model.quota.usedBytes, countStyle: .file))
                                    .font(.title3.bold())
                                    .foregroundStyle(.blue)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Chiếm trên SSD Mac")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(model.driveStatus.cacheBytes), countStyle: .file))
                                    .font(.title3.bold())
                                    .foregroundStyle(.orange)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Đã Tiết Kiệm Cho MacBook")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                let savedBytes = max(0, model.quota.usedBytes - Int64(model.driveStatus.cacheBytes))
                                Text("~ \(ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file))")
                                    .font(.title3.bold())
                                    .foregroundStyle(.green)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Tỷ lệ đám mây")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                let ratio = model.quota.usedBytes > 0
                                    ? Double(max(0, model.quota.usedBytes - Int64(model.driveStatus.cacheBytes))) / Double(model.quota.usedBytes) * 100.0
                                    : 100.0
                                Text(String(format: "%.1f%% Cloud", min(100.0, max(0.0, ratio))))
                                    .font(.callout.bold())
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(8)
                }

                if let notification = model.cacheCleanNotification {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(notification)
                            .font(.caption.bold())
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                // Storage & Cache Cards
                HStack(spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Dung lượng Đám mây (\(model.quota.plan))", systemImage: "icloud.fill")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    model.showPlanPickerSheet = true
                                } label: {
                                    Label("Bảng giá & Định mức", systemImage: "slider.horizontal.3")
                                        .font(.caption2.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            ProgressView(value: Double(model.quota.usedBytes), total: Double(max(1, model.quota.limitBytes)))
                                .tint(.blue)
                            HStack {
                                Text("\(ByteCountFormatter.string(fromByteCount: model.quota.usedBytes, countStyle: .file)) trên tổng \(ByteCountFormatter.string(fromByteCount: model.quota.limitBytes, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Đổi mức dung lượng") {
                                    model.showPlanPickerSheet = true
                                }
                                .font(.caption2)
                                .buttonStyle(.link)
                            }
                        }
                        .padding(6)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Bộ đệm Khối 1 MiB (ChunkStore)", systemImage: "internaldrive.fill")
                                    .font(.headline)
                                Spacer()
                                Button {
                                    model.clearMacCacheAndOptimizeStorage()
                                } label: {
                                    Label("Dọn dẹp SSD", systemImage: "sparkles")
                                        .font(.caption2.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.isClearingCache)
                            }
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
                GroupBox("Tệp trên Ổ đĩa (/Volumes/XDrive)") {
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
                    Button {
                        model.clearMacCacheAndOptimizeStorage()
                    } label: {
                        if model.isClearingCache {
                            ProgressView().controlSize(.small)
                            Text("Đang dọn dẹp SSD...")
                        } else {
                            Label("Giải phóng SSD & Thu nhỏ Đĩa ảo", systemImage: "sparkles")
                        }
                    }
                    .disabled(model.isClearingCache)
                }
                HStack {
                    Text("Dung lượng vật lý của Đĩa ảo trên SSD:")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.physicalBundleSizeBytes), countStyle: .file))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Điều tiết Băng thông Tải lên (PoliteUploads & UploadGovernor)") {
                Toggle("Tải lên lịch sự (Tự động giảm tốc khi phát hiện tăng RTT / Bufferbloat)", isOn: Binding(
                    get: { model.politeUploads },
                    set: { model.updatePoliteUploads($0) }
                ))
                HStack {
                    Text("Phím tắt Mở Spotlight Search Panel:")
                    Spacer()
                    Text("⌘ + ⇧ + K")
                        .font(.system(.callout, design: .monospaced).bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Section("Đám mây Lưu trữ Đa nền tảng (Cloud Storage Provider)") {
                Picker("Nhà cung cấp Lưu trữ:", selection: $model.selectedStorageProvider) {
                    ForEach(MultiCloudProviderType.allCases) { provider in
                        Label(provider.rawValue, systemImage: provider.icon).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: model.selectedStorageProvider) { _, newProvider in
                    model.switchStorageProvider(to: newProvider)
                }

                if model.selectedStorageProvider == .cloudflare {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Máy chủ Cloudflare Workers (D1 SQLite + R2 Storage)")
                                .font(.caption.bold())
                            Spacer()
                            Button {
                                model.showCloudflareGuide = true
                            } label: {
                                Label("Hướng dẫn Kết nối Cloudflare", systemImage: "book.pages.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }

                        HStack {
                            TextField("URL Máy chủ API (VD: https://xdrive.workers.dev hoặc http://127.0.0.1:8787)", text: $model.apiEndpointURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Button("Kiểm tra Kết nối") {
                                model.testCloudflareBackendConnection()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Text(model.backendConnectionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if model.selectedStorageProvider == .googleDrive {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Kết nối Google Drive API v3 (Google Workspace / Personal)")
                                .font(.caption.bold())
                            Spacer()
                            Button {
                                model.showGoogleDriveGuide = true
                            } label: {
                                Label("Hướng dẫn Lấy Token Google", systemImage: "book.pages.fill")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }

                        HStack {
                            SecureField("Google OAuth Access Token (Bearer ya29...)", text: $model.googleDriveAccessToken)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            TextField("Email (Tùy chọn)", text: $model.googleDriveUserEmail)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        }

                        HStack {
                            Button("Kết nối & Tải Quota Google") {
                                model.connectGoogleDrive(accessToken: model.googleDriveAccessToken, email: model.googleDriveUserEmail)
                            }
                            .buttonStyle(.borderedProminent)

                            if !model.googleDriveAccessToken.isEmpty {
                                Button("Ngắt kết nối") {
                                    model.disconnectGoogleDrive()
                                }
                                .buttonStyle(.bordered)
                                .foregroundStyle(.red)
                            }

                            Spacer()

                            Button {
                                Task {
                                    await model.refreshGoogleDriveQuotaAndUser()
                                }
                            } label: {
                                Label("Làm mới Quota", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                        }

                        Text(model.googleDriveStatus)
                            .font(.caption)
                            .foregroundStyle(model.googleDriveStatus.contains("Lỗi") ? .red : .secondary)

                        Text("Ghi chú: Khi bật Mã hóa E2EE, mọi tệp lưu trên Google Drive đều được mã hóa Zero-Knowledge (ChaCha20-Poly1305), bảo vệ dữ liệu tuyệt đối trước Google.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Định Mức Lưu Trữ & Bảng Giá Chi Phí") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Gói hiện tại: \(model.quota.plan)")
                                .font(.headline)
                            Text("Hạn mức: \(ByteCountFormatter.string(fromByteCount: model.quota.limitBytes, countStyle: .file)) • Đã dùng: \(ByteCountFormatter.string(fromByteCount: model.quota.usedBytes, countStyle: .file)) • \(model.quota.fileCount) tệp")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.showPlanPickerSheet = true
                        } label: {
                            Label("Tùy Chỉnh Định Mức & Báo Giá", systemImage: "chart.bar.doc.horizontal.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("Cloudflare R2 miễn phí 10 GB đầu tiên mỗi tháng và 0đ phí băng thông tải về (Zero Egress). Dung lượng vượt quá tính $0.015/GB/tháng (~380 VNĐ/GB).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
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
        .sheet(isPresented: $model.showCloudflareGuide) {
            CloudflareGuideSheet()
        }
        .sheet(isPresented: $model.showGoogleDriveGuide) {
            GoogleDriveGuideSheet()
        }
    }
}

// MARK: - MenuBarPanel (Status Bar Extra Menu)

public struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    @State private var isDropTargeted: Bool = false
    @State private var actionFeedbackMessage: String?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .foregroundStyle(.blue)
                Text("XDrive • \(model.quota.plan)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if case .unlocked = model.privacyState {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                }
            }

            Divider()

            // Quota
            VStack(alignment: .leading, spacing: 4) {
                Text("Đã dùng: \(ByteCountFormatter.string(fromByteCount: model.quota.usedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.quota.limitBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(model.quota.usedBytes), total: Double(max(1, model.quota.limitBytes)))
                    .tint(.blue)
            }

            // Quick Cloud Provider Switcher in Menu Bar Popup
            VStack(alignment: .leading, spacing: 4) {
                Text("Đám mây lưu trữ:")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.selectedStorageProvider) {
                    Label("Cloudflare", systemImage: "cloud.fill").tag(MultiCloudProviderType.cloudflare)
                    Label("Google Drive", systemImage: "externaldrive.fill.badge.icloud").tag(MultiCloudProviderType.googleDrive)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.selectedStorageProvider) { _, newP in
                    model.switchStorageProvider(to: newP)
                }
            }

            // Direct Drag & Drop Zone inside Menu Bar
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isDropTargeted ? "Thả tệp vào đây ngay!" : "Kéo thả tệp vào đây")
                        .font(.caption.bold())
                    Text("Tự động đồng bộ & sao chép link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(isDropTargeted ? Color.blue.opacity(0.18) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isDropTargeted ? Color.blue : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                model.handleDroppedItemProviders(providers)
                return true
            }

            if let msg = actionFeedbackMessage ?? (model.lastCopiedShareURL != nil ? "Đã sao chép liên kết chia sẻ E2EE" : nil) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(msg)
                        .font(.caption2.bold())
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }

            Divider()

            // Menu Buttons
            VStack(spacing: 6) {
                menuButton(title: "Mở Bảng Điều Khiển XDrive", icon: "macwindow", color: .blue) {
                    model.openMainWindow()
                }

                menuButton(title: "Mở /Volumes/XDrive trong Finder", icon: "folder.fill", color: .blue) {
                    model.mountOrOpenDrive()
                }

                menuButton(
                    title: model.isClearingCache ? "Đang giải phóng SSD Mac..." : "Giải phóng dung lượng SSD Mac",
                    icon: "sparkles",
                    color: .orange
                ) {
                    model.clearMacCacheAndOptimizeStorage()
                    actionFeedbackMessage = "Đang tối ưu & giải phóng SSD Mac..."
                }

                menuButton(
                    title: model.privacyState == .off ? "Bật Mã hóa Zero-Knowledge E2EE" : "Sao chép Mã Khôi phục E2EE",
                    icon: "lock.shield.fill",
                    color: .green
                ) {
                    if let code = model.keyManager.recoveryCode() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        actionFeedbackMessage = "Đã sao chép mã khôi phục!"
                    } else {
                        model.enableZeroKnowledgeEncryption()
                        actionFeedbackMessage = "Đã kích hoạt Zero-Knowledge E2EE!"
                    }
                }

                menuButton(title: "Kiểm tra Bản cập nhật trên GitHub", icon: "arrow.triangle.2.circlepath", color: .purple) {
                    Task {
                        await model.updater.checkForUpdates(silent: false)
                        await MainActor.run {
                            actionFeedbackMessage = "Đã kiểm tra bản cập nhật mới nhất!"
                        }
                    }
                }

                Divider()

                menuButton(title: "Thoát XDrive", icon: "power", color: .red) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func menuButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(color == .red ? .red : .primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

// MARK: - Cloudflare & Google Drive Connection Guides (In-App Step-by-Step Modals)

public struct CloudflareGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hướng dẫn Kết nối Cloudflare Workers (D1 + R2)")
                        .font(.title2.bold())
                    Text("Triển khai backend đám mây riêng của bạn với chi phí 0đ và không phí băng thông")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    guideStep(
                        step: "1",
                        title: "Cài đặt Cloudflare Wrangler CLI",
                        desc: "Mở Terminal trên máy Mac và kiểm tra hoặc cài đặt công cụ dòng lệnh của Cloudflare:",
                        code: "npm install -g wrangler\nnpx wrangler login"
                    )

                    guideStep(
                        step: "2",
                        title: "Tạo Cơ sở dữ liệu D1 & Thùng chứa R2",
                        desc: "Khởi tạo tài nguyên lưu trữ miễn phí trên tài khoản Cloudflare của bạn:",
                        code: "npx wrangler d1 create xdrive-db\nnpx wrangler r2 bucket create xdrive-bucket"
                    )

                    guideStep(
                        step: "3",
                        title: "Triển khai Worker Backend (Thư mục x-drive/backend)",
                        desc: "Khởi tạo bảng cơ sở dữ liệu và triển khai mã nguồn API lên mạng lưới biên toàn cầu:",
                        code: "cd x-drive/backend\nnpx wrangler d1 execute xdrive-db --file=schema.sql --remote\nnpm run deploy"
                    )

                    guideStep(
                        step: "4",
                        title: "Dán URL Máy chủ vào XDrive",
                        desc: "Sau khi lệnh deploy hoàn tất, sao chép địa chỉ Worker được cấp (ví dụ: `https://xdrive-api.<subdomain>.workers.dev`) và dán vào ô 'URL Máy chủ API' trong tab Cài đặt, sau đó bấm 'Kiểm tra Kết nối'."
                    )

                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Mẹo: Nếu muốn chạy thử nghiệm nội bộ trên máy, chạy lệnh `npm run dev` trong thư mục backend rồi nhập URL `http://127.0.0.1:8787`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.vertical, 6)
            }

            HStack {
                Spacer()
                Button("Đã hiểu & Đóng") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 600, height: 520)
    }

    private func guideStep(step: String, title: String, desc: String, code: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Color.orange.opacity(0.18), in: Circle())
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let code {
                    HStack {
                        Text(code)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Sao chép lệnh")
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

public struct GoogleDriveGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hướng dẫn Kết nối Google Drive (API v3)")
                        .font(.title2.bold())
                    Text("Đồng bộ trực tiếp với Google Drive và mã hóa Zero-Knowledge E2EE bảo mật")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cách 1: Lấy Mã Truy cập Nhanh qua Google OAuth Playground (1 Phút)")
                            .font(.headline)
                            .foregroundStyle(.blue)

                        Text("Thích hợp để thử nghiệm và kết nối nhanh tài khoản Google Drive cá nhân:")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Mở trang Google OAuth 2.0 Playground bằng trình duyệt:")
                                .font(.caption)
                            Link("👉 Mở developers.google.com/oauthplayground", destination: URL(string: "https://developers.google.com/oauthplayground")!)
                                .font(.caption.bold())

                            Text("2. Ở cột bên trái (Step 1), cuộn xuống mục **Drive API v3** và tích chọn:")
                                .font(.caption)
                            Text("https://www.googleapis.com/auth/drive")
                                .font(.system(.caption2, design: .monospaced))
                                .padding(4)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))

                            Text("3. Nhấn nút xanh **Authorize APIs** và đăng nhập vào tài khoản Google của bạn.")
                                .font(.caption)

                            Text("4. Ở Bước 2 (Step 2), nhấn nút xanh **Exchange authorization code for tokens**.")
                                .font(.caption)

                            Text("5. Sao chép giá trị trong ô **Access token** (bắt đầu bằng `ya29...`) và dán vào ô 'Google OAuth Access Token' trong XDrive.")
                                .font(.caption)
                        }
                        .padding(10)
                        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cách 2: Đăng ký OAuth 2.0 Client ID trên Google Cloud Console")
                            .font(.headline)

                        Text("Thích hợp cho doanh nghiệp hoặc sử dụng lâu dài ổn định:")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Truy cập [Google Cloud Console](https://console.cloud.google.com) và tạo một Project mới.")
                                .font(.caption)
                            Text("2. Vào mục **APIs & Services** > **Library**, tìm kiếm và nhấn **Enable** cho thư viện **Google Drive API**.")
                                .font(.caption)
                            Text("3. Vào **Credentials** > **Create Credentials** > **OAuth client ID**, chọn Application type là **Desktop app**.")
                                .font(.caption)
                            Text("4. Tạo Authorized Redirect URI `http://127.0.0.1:8787/auth/callback` và dùng mã truy cập cấp quyền cho XDrive.")
                                .font(.caption)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }

                    HStack {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.green)
                        Text("Bảo mật tuyệt đối: Khi bạn kích hoạt 'Bật Mã hóa E2EE', các tệp lưu trên Google Drive sẽ được mã hóa hoàn toàn trước khi tải lên. Google và bên thứ ba không thể xem nội dung dữ liệu của bạn.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button("Đã hiểu & Đóng") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 620, height: 540)
    }
}


