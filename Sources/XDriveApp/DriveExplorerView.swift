import AppKit
import SwiftUI
import OrbitCore

// MARK: - DriveExplorerView (Full Interactive Virtual Drive File Manager & Inspector)

public struct DriveExplorerView: View {
    @ObservedObject var model: AppModel
    @State private var newFolderName: String = ""
    @State private var isCreatingFolder: Bool = false
    @State private var renamingNode: DriveNode?
    @State private var renameText: String = ""
    @State private var selectedNode: DriveNode?
    @State private var previewText: String = ""
    @State private var fileRequestBannerURL: String?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HSplitView {
            // Left: Breadcrumb + Toolbar + Directory Listing
            VStack(alignment: .leading, spacing: 0) {
                // Top Breadcrumb & Action Bar
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.explorerBreadcrumbs.enumerated()), id: \.element.id) { idx, crumb in
                            if idx > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                model.navigateExplorer(to: crumb.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: crumb.id == DriveTree.rootID ? "externaldrive.fill" : "folder.fill")
                                    Text(crumb.id == DriveTree.rootID ? "/Volumes/XDrive" : crumb.name)
                                }
                                .font(.callout.weight(crumb.id == model.currentExplorerDirectoryID ? .bold : .regular))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(crumb.id == model.currentExplorerDirectoryID ? .primary : .secondary)
                        }
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Button {
                            isCreatingFolder.toggle()
                        } label: {
                            Label("Thư mục Mới", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            pickAndUploadFilesToCurrentDirectory()
                        } label: {
                            Label("Tải Tệp Lên", systemImage: "arrow.up.doc.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            let url = model.createFileRequestForCurrentFolder()
                            fileRequestBannerURL = url
                        } label: {
                            Label("Nhận Tệp (File Request E2EE)", systemImage: "tray.and.arrow.down.fill")
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            model.refreshCurrentExplorerDirectory()
                        } label: {
                            Label("Làm mới", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    if isCreatingFolder {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill.badge.plus")
                                .foregroundStyle(.blue)
                            TextField("Nhập tên thư mục mới...", text: $newFolderName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    createFolderAction()
                                }
                            Button("Tạo") {
                                createFolderAction()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Hủy") {
                                isCreatingFolder = false
                                newFolderName = ""
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let reqURL = fileRequestBannerURL {
                        HStack {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .foregroundStyle(.blue)
                            Text("Đã chép liên kết Nhận tệp (Curve25519/P-256 Drop): \(reqURL)")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Spacer()
                            Button {
                                fileRequestBannerURL = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)

                Divider()

                // Directory Children List
                if model.explorerItems.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Thư mục này đang trống")
                            .font(.headline)
                        Text("Nhấn 'Tải Tệp Lên' hoặc 'Thư mục Mới' để thêm dữ liệu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: Binding(
                        get: { selectedNode?.id },
                        set: { newID in
                            if let id = newID, let found = model.explorerItems.first(where: { $0.id == id }) {
                                selectNode(found)
                            }
                        }
                    )) {
                        ForEach(model.explorerItems) { node in
                            HStack(spacing: 12) {
                                Image(systemName: node.kind == .directory ? "folder.fill" : "doc.text.fill")
                                    .font(.title3)
                                    .foregroundStyle(node.kind == .directory ? .blue : .secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(node.name)
                                            .font(.body.weight(.medium))
                                        if node.kind == .file {
                                            if model.isNodePinned(node) {
                                                Label("Đã ghim Offline", systemImage: "pin.fill")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.orange.opacity(0.15), in: Capsule())
                                                    .foregroundStyle(.orange)
                                            } else {
                                                Label("Chỉ trên Mây (0B SSD)", systemImage: "icloud")
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.blue.opacity(0.1), in: Capsule())
                                                    .foregroundStyle(.blue)
                                            }
                                        }
                                        if case .unlocked = model.privacyState {
                                            Image(systemName: "lock.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                                .help("Đã mã hóa Zero-Knowledge AES-256-GCM")
                                        }
                                    }
                                    Text("Inode #\(node.id) • Phiên bản v\(node.contentVersion) • \(node.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if node.kind == .file {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(node.size), countStyle: .file))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    Button {
                                        model.togglePinNode(node)
                                    } label: {
                                        Image(systemName: model.isNodePinned(node) ? "pin.slash.fill" : "pin")
                                            .foregroundStyle(model.isNodePinned(node) ? .orange : .secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .help(model.isNodePinned(node) ? "Bỏ ghim 'Keep on This Mac'" : "Ghim ngoại tuyến ('Keep on This Mac')")
                                }

                                Button {
                                    model.createShareLinkForDriveNode(node)
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                                .help("Sao chép liên kết chia sẻ (#sk=...)")

                                Button {
                                    renamingNode = node
                                    renameText = node.name
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Đổi tên")

                                Button(role: .destructive) {
                                    if selectedNode?.id == node.id {
                                        selectedNode = nil
                                    }
                                    model.deleteExplorerNode(node)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .help("Xóa")
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .contextMenu {
                                if node.kind == .file {
                                    if model.isNodePinned(node) {
                                        Button {
                                            model.evictNodeChunks(node)
                                        } label: {
                                            Label("Giải phóng SSD (Chỉ lưu trên Đám mây)", systemImage: "sparkles")
                                        }
                                    } else {
                                        Button {
                                            model.togglePinNode(node)
                                        } label: {
                                            Label("Tải về & Giữ ngoại tuyến trên Mac", systemImage: "pin.fill")
                                        }
                                    }
                                }
                                Button {
                                    model.createShareLinkForDriveNode(node)
                                } label: {
                                    Label("Sao chép Liên kết Chia sẻ E2EE", systemImage: "square.and.arrow.up")
                                }
                                Button {
                                    renamingNode = node
                                    renameText = node.name
                                } label: {
                                    Label("Đổi tên", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    if selectedNode?.id == node.id {
                                        selectedNode = nil
                                    }
                                    model.deleteExplorerNode(node)
                                } label: {
                                    Label("Xóa", systemImage: "trash")
                                }
                            }
                            .onTapGesture(count: 2) {
                                if node.kind == .directory {
                                    model.navigateExplorer(to: node.id)
                                    selectedNode = nil
                                } else {
                                    selectNode(node)
                                }
                            }
                            .onTapGesture(count: 1) {
                                selectNode(node)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 460)

            // Right: Live File / Inode Inspector Panel
            if let item = selectedNode {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: item.kind == .directory ? "folder.fill" : "doc.text.magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text(item.name)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            selectedNode = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()

                    GroupBox("Siêu dữ liệu Inode (OrbitFS / DriveTree)") {
                        VStack(alignment: .leading, spacing: 6) {
                            inspectorRow("Inode ID:", "#\(item.id)")
                            inspectorRow("Remote ID:", item.remoteID ?? "local_staged")
                            inspectorRow("Loại Node:", item.kind == .directory ? "Thư mục (Directory)" : "Tệp (File)")
                            inspectorRow("Kích thước:", ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                            inspectorRow("Phiên bản Khối:", "v\(item.contentVersion)")
                            inspectorRow("Ghim Offline:", model.isNodePinned(item) ? "Có (Keep on This Mac)" : "Không (Thu hồi LRU tự động)")
                            inspectorRow("Chế độ E2EE:", model.keyManager.keys != nil ? "AES-256-GCM (1 MiB Pieces)" : "Plaintext")
                        }
                        .padding(6)
                    }

                    if item.kind == .directory {
                        Button {
                            model.navigateExplorer(to: item.id)
                            selectedNode = nil
                        } label: {
                            Label("Mở Thư mục Này", systemImage: "arrow.right.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        HStack(spacing: 8) {
                            if model.isNodePinned(item) {
                                Button {
                                    model.evictNodeChunks(item)
                                } label: {
                                    Label("Giải phóng SSD", systemImage: "sparkles")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                            } else {
                                Button {
                                    model.togglePinNode(item)
                                } label: {
                                    Label("Ghim Ngoại Tuyến", systemImage: "pin.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                            }
                        }

                        GroupBox("Xem trước Nội dung Khối 1 MiB (ContentReader)") {
                            ScrollView {
                                Text(previewText.isEmpty ? "(Đang đọc khối dữ liệu...)" : previewText)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(minHeight: 140, maxHeight: 240)
                            .padding(6)
                        }
                    }

                    Spacer()
                }
                .padding(16)
                .frame(minWidth: 260, maxWidth: 320)
                .background(.quaternary.opacity(0.2))
            }
        }
        .sheet(item: $renamingNode) { target in
            VStack(spacing: 16) {
                Text("Đổi tên '\(target.name)'")
                    .font(.headline)
                TextField("Tên mới", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                HStack(spacing: 12) {
                    Button("Hủy") {
                        renamingNode = nil
                    }
                    Button("Lưu") {
                        model.renameExplorerNode(target, newName: renameText)
                        renamingNode = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
    }

    private func inspectorRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
        }
    }

    private func createFolderAction() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.createExplorerFolder(name: trimmed)
        newFolderName = ""
        isCreatingFolder = false
    }

    private func selectNode(_ node: DriveNode) {
        selectedNode = node
        guard node.kind == .file else {
            previewText = ""
            return
        }
        Task {
            let slice = (try? await model.drive.readFile(nodeID: node.id, offset: 0, length: 2048)) ?? Data()
            if let str = String(data: slice, encoding: .utf8), !str.isEmpty {
                previewText = str
            } else {
                let hex = slice.prefix(128).map { String(format: "%02X", $0) }.joined(separator: " ")
                previewText = "[Dữ liệu Nhị phân — 128 bytes đầu]:\n\(hex)"
            }
        }
    }

    private func pickAndUploadFilesToCurrentDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Tải lên Thư mục Hiện tại"
        if panel.runModal() == .OK {
            model.dropFiles(panel.urls, intoParentID: model.currentExplorerDirectoryID)
        }
    }
}
