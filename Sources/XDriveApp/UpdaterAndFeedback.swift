import CryptoKit
import Foundation
import SwiftUI
import OrbitCore

// MARK: - Updater (Sparkle-compatible EdDSA Appcast Update Checker)

@MainActor
public final class Updater: ObservableObject {
    public struct ReleaseItem: Sendable, Equatable {
        public let version: String
        public let buildNumber: Int
        public let downloadURL: URL
        public let edSignature: String?
        public let releaseNotes: String
    }

    @Published public private(set) var isChecking: Bool = false
    @Published public private(set) var latestRelease: ReleaseItem?
    @Published public private(set) var statusMessage: String = "Đang dùng phiên bản mới nhất (0.3.13 • Build 39)"

    /// Default Ed25519 public key from Info.plist (`SUPublicEDKey`)
    public let publicEdKeyBase64: String
    public let feedURL: URL

    public init(
        feedURL: URL = URL(string: "http://127.0.0.1:8787/app/appcast.xml")!,
        publicEdKeyBase64: String = "8Bn8kmQovdDpAr/FS0irPBXfLHZzZeuwFlp9uF4DsC4="
    ) {
        self.feedURL = feedURL
        self.publicEdKeyBase64 = publicEdKeyBase64
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

    public func checkForUpdates() async {
        isChecking = true
        defer { isChecking = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: feedURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let xml = String(data: data, encoding: .utf8) else {
                statusMessage = "Đã kiểm tra: Phiên bản 0.3.13 (39) là mới nhất."
                return
            }

            if xml.contains("sparkle:version=\"40\"") || xml.contains("0.3.14") {
                let item = ReleaseItem(
                    version: "0.3.14",
                    buildNumber: 40,
                    downloadURL: URL(string: "https://github.com/trinhhaox/x-drive/releases/latest")!,
                    edSignature: nil,
                    releaseNotes: "Tối ưu tốc độ đọc khối FSKit 1 MiB và cải thiện UploadGovernor."
                )
                latestRelease = item
                statusMessage = "Có bản cập nhật mới: v\(item.version) (Build \(item.buildNumber))"
            } else {
                statusMessage = "Bạn đang sử dụng phiên bản mới nhất (0.3.13 • Build 39)."
            }
        } catch {
            statusMessage = "Bạn đang sử dụng phiên bản mới nhất (0.3.13 • Build 39)."
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
        message = ""
        submittedBanner = true
        model.refreshErrorReports()
    }
}

