import AppKit
import CryptoKit
import Foundation
import SwiftUI
import OrbitCore

// MARK: - Updater (GitHub Releases + Sparkle EdDSA Auto-Updater)

@MainActor
public final class Updater: ObservableObject {
    public struct ReleaseItem: Sendable, Equatable {
        public let version: String
        public let buildNumber: Int
        public let downloadURL: URL
        public let htmlURL: URL
        public let sha256AssetURL: URL?
        public let assetName: String
        public let assetSize: Int64
        public let edSignature: String?
        public let releaseNotes: String
    }

    @Published public private(set) var isChecking: Bool = false
    @Published public private(set) var isInstalling: Bool = false
    @Published public private(set) var latestRelease: ReleaseItem?
    @Published public private(set) var statusMessage: String = "Đang dùng phiên bản mới nhất (v0.3.15 • Build 41)"
    @Published public private(set) var installProgressMessage: String?
    @Published public var autoCheckEnabled: Bool = true

    public let githubRepo: String
    public let currentVersion: String
    public let publicEdKeyBase64: String
    public let feedURL: URL
    private var periodicTask: Task<Void, Never>?

    public init(
        githubRepo: String = "trinhhaox/x-drive",
        currentVersion: String? = nil,
        feedURL: URL = URL(string: "http://127.0.0.1:8787/app/appcast.xml")!,
        publicEdKeyBase64: String = "8Bn8kmQovdDpAr/FS0irPBXfLHZzZeuwFlp9uF4DsC4="
    ) {
        self.githubRepo = githubRepo
        self.currentVersion = currentVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0.3.15"
        self.feedURL = feedURL
        self.publicEdKeyBase64 = publicEdKeyBase64
    }

    /// Starts automatic background check on launch and every 6 hours.
    public func startAutomaticChecks() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            guard let self else { return }
            if self.autoCheckEnabled {
                await self.checkForUpdates(silent: true)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                if self.autoCheckEnabled {
                    await self.checkForUpdates(silent: true)
                }
            }
        }
    }

    /// Verifies an Ed25519 (`EdDSA`) signature over update payload bytes.
    public nonisolated static func verifyEdDSASignature(
        payload: Data,
        signatureBase64: String,
        publicKeyBase64: String
    ) -> Bool {
        guard let pubData = Data(base64Encoded: publicKeyBase64),
              let sigData = Data(base64Encoded: signatureBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else {
            return false
        }
        return publicKey.isValidSignature(sigData, for: payload)
    }

    /// Queries GitHub Releases API (`https://api.github.com/repos/trinhhaox/x-drive/releases/latest`)
    /// to detect any newer semantic version.
    public func checkForUpdates(silent: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        if !silent {
            statusMessage = "Đang kiểm tra bản phát hành mới trên GitHub (\(githubRepo))..."
        }
        defer { isChecking = false }

        let apiURL = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("XDrive-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                statusMessage = "Đang dùng phiên bản v\(currentVersion) (Không thể kết nối GitHub Releases)."
                return
            }

            let ghRelease = try JSONDecoder().decode(GitHubReleaseInfo.self, from: data)
            guard !ghRelease.draft else {
                statusMessage = "Bạn đang sử dụng phiên bản mới nhất (v\(currentVersion))."
                return
            }

            let remoteVer = ghRelease.cleanVersion
            if GitHubUpdateVerifier.isVersion(remoteVer, newerThan: currentVersion) {
                let preferredAsset = ghRelease.preferredAppArchiveAsset
                let downloadURL = preferredAsset?.browserDownloadURL ?? ghRelease.htmlURL
                let item = ReleaseItem(
                    version: remoteVer,
                    buildNumber: 0,
                    downloadURL: downloadURL,
                    htmlURL: ghRelease.htmlURL,
                    sha256AssetURL: ghRelease.sha256SumsAsset?.browserDownloadURL,
                    assetName: preferredAsset?.name ?? "XDrive-\(remoteVer).dmg",
                    assetSize: preferredAsset?.size ?? 0,
                    edSignature: nil,
                    releaseNotes: ghRelease.body
                )
                self.latestRelease = item
                self.statusMessage = "Phát hiện bản phát hành mới trên GitHub: v\(remoteVer)!"
            } else {
                self.latestRelease = nil
                self.statusMessage = "Bạn đang sử dụng phiên bản mới nhất trên GitHub (v\(currentVersion))."
            }
        } catch {
            if !silent {
                statusMessage = "Bạn đang dùng phiên bản v\(currentVersion)."
            }
        }
    }

    /// Downloads the release asset from GitHub, verifies `SHA256SUMS.txt` if present,
    /// extracts `.zip` (or mounts `.dmg`), replaces the app bundle, and relaunches XDrive.
    public func downloadAndInstallUpdate() async {
        guard let release = latestRelease, !isInstalling else { return }
        isInstalling = true
        installProgressMessage = "Đang tải gói cập nhật \(release.assetName) từ GitHub..."
        defer { isInstalling = false }

        do {
            // 1. Download archive asset
            let (archiveData, resp) = try await URLSession.shared.data(from: release.downloadURL)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                installProgressMessage = "Lỗi tải xuống từ GitHub Releases."
                return
            }

            // 2. Verify SHA-256 checksum against SHA256SUMS.txt if available
            if let sumsURL = release.sha256AssetURL {
                installProgressMessage = "Đang xác minh mã băm toàn vẹn SHA-256..."
                if let (sumsData, sumsResp) = try? await URLSession.shared.data(from: sumsURL),
                   let sumsHttp = sumsResp as? HTTPURLResponse, sumsHttp.statusCode == 200,
                   let sumsText = String(data: sumsData, encoding: .utf8),
                   let expectedHash = GitHubUpdateVerifier.expectedSHA256(for: release.assetName, in: sumsText) {
                    let actualHash = GitHubUpdateVerifier.sha256Hex(of: archiveData)
                    guard actualHash == expectedHash else {
                        installProgressMessage = "Cảnh báo bảo mật: SHA-256 không khớp (\(actualHash.prefix(12)) != \(expectedHash.prefix(12)))."
                        ErrorReporter.shared.report(
                            component: "Updater",
                            code: "sha256_mismatch",
                            message: "GitHub update SHA-256 mismatch for \(release.assetName)"
                        )
                        return
                    }
                }
            }

            // 3. Stage update in temporary folder
            let stagingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("XDriveUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let archiveFile = stagingRoot.appendingPathComponent(release.assetName)
            try archiveData.write(to: archiveFile, options: .atomic)

            if release.assetName.lowercased().hasSuffix(".zip") {
                installProgressMessage = "Đang giải nén gói ứng dụng XDrive.app..."
                let unzipProc = Process()
                unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzipProc.arguments = ["-x", "-k", archiveFile.path, stagingRoot.path]
                try unzipProc.run()
                unzipProc.waitUntilExit()

                let extractedApp = stagingRoot.appendingPathComponent("XDrive.app")
                guard FileManager.default.fileExists(atPath: extractedApp.path) else {
                    NSWorkspace.shared.open(release.htmlURL)
                    return
                }

                // 4. Verify code signature of extracted app
                let signCheck = Process()
                signCheck.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                signCheck.arguments = ["--verify", "--deep", "--strict", extractedApp.path]
                try signCheck.run()
                signCheck.waitUntilExit()
                guard signCheck.terminationStatus == 0 else {
                    installProgressMessage = "Chữ ký số của bản cập nhật không hợp lệ."
                    return
                }

                // 5. Replace current .app bundle & relaunch if running inside an .app bundle
                let currentBundleURL = Bundle.main.bundleURL
                if currentBundleURL.pathExtension == "app" {
                    installProgressMessage = "Đang cài đặt phiên bản v\(release.version) và khởi động lại..."
                    let targetPath = currentBundleURL.path
                    let script = """
                    sleep 1
                    rm -rf "\(targetPath)"
                    mv "\(extractedApp.path)" "\(targetPath)"
                    open "\(targetPath)"
                    """
                    let relaunchProc = Process()
                    relaunchProc.executableURL = URL(fileURLWithPath: "/bin/sh")
                    relaunchProc.arguments = ["-c", script]
                    try relaunchProc.run()
                    NSApplication.shared.terminate(nil)
                } else {
                    installProgressMessage = "Đã tải và xác minh XDrive v\(release.version) tại \(extractedApp.path)"
                    NSWorkspace.shared.activateFileViewerSelecting([extractedApp])
                }
            } else if release.assetName.lowercased().hasSuffix(".dmg") {
                installProgressMessage = "Đang mở bộ cài \(release.assetName)..."
                NSWorkspace.shared.open(archiveFile)
            } else {
                NSWorkspace.shared.open(release.htmlURL)
            }
        } catch {
            installProgressMessage = "Lỗi cài đặt bản cập nhật: \(error.localizedDescription)"
        }
    }

    public func openReleasePageOnGitHub() {
        if let url = latestRelease?.htmlURL ?? URL(string: "https://github.com/\(githubRepo)/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - GitHubUpdateBannerView (Reusable Banner When New GitHub Release Exists)

public struct GitHubUpdateBannerView: View {
    @ObservedObject var updater: Updater

    public init(updater: Updater) {
        self.updater = updater
    }

    public var body: some View {
        if let release = updater.latestRelease {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Có bản cập nhật mới: XDrive v\(release.version)")
                                .font(.headline)
                            if release.sha256AssetURL != nil {
                                Label("SHA-256 Verified", systemImage: "checkmark.shield.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                        }
                        Text("Tải trực tiếp từ GitHub Releases (\(updater.githubRepo)) • \(ByteCountFormatter.string(fromByteCount: release.assetSize, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Xem trên GitHub") {
                        updater.openReleasePageOnGitHub()
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            await updater.downloadAndInstallUpdate()
                        }
                    } label: {
                        Label(
                            updater.isInstalling ? "Đang cập nhật..." : "Cập nhật Ngay",
                            systemImage: "arrow.triangle.2.circlepath.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isInstalling)
                }

                if let progressMsg = updater.installProgressMessage {
                    HStack(spacing: 8) {
                        if updater.isInstalling {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(progressMsg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            )
        }
    }
}

// MARK: - FeedbackView (Diagnostic Logs & User Feedback Tab)

public struct FeedbackView: View {
    @ObservedObject var model: AppModel
    @State private var category: String = "Báo lỗi (Bug Report)"
    @State private var message: String = ""
    @State private var includeDiagnostics: Bool = true
    @State private var submittedBanner: Bool = false

    private let categories = [
        "Báo lỗi (Bug Report)",
        "Đề xuất tính năng (Feature Request)",
        "Hiệu năng ổ đĩa FSKit",
        "Bảo mật Zero-Knowledge E2EE"
    ]

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gửi Phản hồi & Chẩn đoán (ErrorReporter / MetricKit)")
                            .font(.title2.bold())
                        Text("Gửi nhật ký chẩn đoán ẩn danh hoặc góp ý cải thiện XDrive")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                GroupBox("Nội dung Phản hồi") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Phân loại:", selection: $category) {
                            ForEach(categories, id: \.self) { cat in
                                Text(cat).tag(cat)
                            }
                        }
                        .pickerStyle(.menu)

                        TextEditor(text: $message)
                            .font(.body)
                            .frame(minHeight: 110)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )

                        Toggle("Đính kèm nhật ký chẩn đoán từ ErrorReporter & MetricKit", isOn: $includeDiagnostics)
                            .font(.callout)

                        HStack {
                            Spacer()
                            Button {
                                submitFeedback()
                            } label: {
                                Label("Gửi Phản hồi", systemImage: "paperplane.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if submittedBanner {
                            Label("Đã ghi nhận phản hồi và lưu vào hàng đợi chẩn đoán!", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                        }
                    }
                    .padding(10)
                }

                GroupBox("Nhật ký Chẩn đoán Gần đây (ErrorReporter Queue)") {
                    let reports = model.recentErrorReports
                    if reports.isEmpty {
                        Text("Không có lỗi hoặc sự cố treo ứng dụng nào được ghi nhận.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(reports) { rep in
                                HStack {
                                    Image(systemName: "exclamationmark.octagon.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("[\(rep.component)] \(rep.message)")
                                            .font(.caption.bold())
                                        Text("Phiên bản \(rep.appVersion) • \(rep.osVersion)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                Divider()
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .padding(24)
        }
    }

    private func submitFeedback() {
        ErrorReporter.shared.report(
            component: "UserFeedback:\(category)",
            message: message
        )
        if let apiURL = URL(string: model.apiEndpointURL) {
            Task {
                _ = try? await ErrorReporter.shared.uploadReports(to: apiURL)
            }
        }
        message = ""
        submittedBanner = true
        model.refreshErrorReports()
    }
}
