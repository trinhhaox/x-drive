import SwiftUI
import UniformTypeIdentifiers
import OrbitCore

// MARK: - FileDropArea (Drag & Drop Upload Component)

public struct FileDropArea: View {
    @ObservedObject var model: AppModel
    @State private var isTargeted: Bool = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "icloud.and.arrow.up.fill")
                .font(.system(size: 30))
                .foregroundStyle(isTargeted ? .green : .blue)
            Text("Kéo và thả tệp vào đây để tải lên /Volumes/XDrive")
                .font(.subheadline.weight(.semibold))
            Text(model.privacyState == .off
                 ? "Tệp sẽ được ghi qua Staging & đồng bộ qua 2 làn ưu tiên (Small/Big Lanes)"
                 : "Tệp sẽ được mã hóa tự động theo từng khối 1 MiB (AES-256-GCM) trước khi tải lên")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Chọn tệp từ máy Mac...") {
                chooseFilesFromPanel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.green : Color.blue.opacity(0.45),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
                .background(
                    (isTargeted ? Color.green.opacity(0.08) : Color.blue.opacity(0.03)),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        Task { @MainActor in
                            model.dropFiles([url])
                        }
                    }
                }
            }
            return true
        }
    }

    private func chooseFilesFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            model.dropFiles(panel.urls)
        }
    }
}

// MARK: - Upload Cards (Uploading, Failed, Recent & Share Links)

public struct UploadActivitySection: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.driveStatus.uploadingFiles.isEmpty {
                GroupBox("Đang tải lên (\(model.driveStatus.uploadingFiles.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.driveStatus.uploadingFiles) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.name)
                                        .font(.callout.weight(.medium))
                                    Spacer()
                                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.bytesSent), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: Double(item.bytesSent), total: Double(max(1, item.size)))
                            }
                        }
                    }
                    .padding(6)
                }
            }

            if !model.driveStatus.failedUploads.isEmpty {
                GroupBox("Tải lên thất bại (\(model.driveStatus.failedUploads.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.driveStatus.failedUploads) { fail in
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fail.name)
                                        .font(.callout.weight(.medium))
                                    Text(fail.reason)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Thử lại") {
                                    Task {
                                        await model.drive.flushStagedNode(nodeID: fail.id)
                                        model.refreshSnapshot()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(6)
                }
            }

            if !model.driveStatus.recentUploads.isEmpty {
                GroupBox("Đã tải lên gần đây") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.driveStatus.recentUploads.prefix(5)) { rec in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(rec.name)
                                    .font(.callout)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(rec.size), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }
}

