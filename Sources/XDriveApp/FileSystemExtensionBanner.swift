import SwiftUI
import OrbitCore

// MARK: - FileSystemExtensionBanner (Guide the user to switch OrbitFS back on)

/// Shown while the drive cannot mount because macOS has the OrbitFS module turned
/// off, which happens after every install or update. Retries when XDrive regains focus.
struct FileSystemExtensionBanner: View {
    @ObservedObject var driveController: DriveController

    var body: some View {
        if driveController.state == .NeedsExtensionApproval {
            VStack(alignment: .leading, spacing: 10) {
                Label("Cần bật OrbitFS để gắn ổ XDrive", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("macOS tắt tiện ích hệ thống tệp của XDrive sau mỗi lần cài hoặc cập nhật.")
                    .font(.callout)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Bấm \"Mở Cài đặt hệ thống\".")
                    Text("2. Ở mục Tiện ích mở rộng, bấm ⓘ cạnh \"XDrive\".")
                    Text("3. Bật \"FSKit Modules\" rồi quay lại XDrive. Ổ sẽ tự gắn.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Mở Cài đặt hệ thống") {
                        NSWorkspace.shared.open(FileSystemModuleStatus.settingsURL)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Thử lại") { retryMount() }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                retryMount()
            }
        }
    }

    private func retryMount() {
        Task { await driveController.mountDrive() }
    }
}
