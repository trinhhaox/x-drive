import Cocoa
import SwiftUI
import OrbitCore

// MARK: - SearchPanel & SearchPanelController (Floating Spotlight-Style NSPanel)

public final class SearchPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .closable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = true
    }
}

@MainActor
public final class SearchPanelController {
    private var panel: SearchPanel?
    private weak var appModel: AppModel?

    public init(appModel: AppModel) {
        self.appModel = appModel
    }

    public func togglePanel() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    public func showPanel() {
        guard let appModel else { return }
        if panel == nil {
            let rect = NSRect(x: 0, y: 0, width: 620, height: 420)
            let p = SearchPanel(contentRect: rect)
            p.contentView = NSHostingView(
                rootView: FloatingSearchPanelView(model: appModel) { [weak p] in
                    p?.orderOut(nil)
                }
            )
            p.center()
            self.panel = p
        }
        appModel.refreshSnapshot()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

public struct FloatingSearchPanelView: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void
    @State private var selectedIndex: Int = 0

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("Tìm nhanh tệp trên /Volumes/XDrive (↑↓ chọn, Enter mở, Esc đóng)...", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onChange(of: model.searchQuery) { _, _ in
                        selectedIndex = 0
                        model.performSearch()
                    }
                    .onSubmit {
                        openSelectedNode()
                    }
                Button("Đóng") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.searchResults.enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 12) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text.fill")
                                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                                .font(.title3)
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
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            idx == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedIndex = idx
                            openSelectedNode()
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .frame(width: 620, height: 420)
    }

    private func openSelectedNode() {
        guard model.searchResults.indices.contains(selectedIndex) else { return }
        let target = model.searchResults[selectedIndex]
        let url = URL(fileURLWithPath: MountHelper.mountPoint).appendingPathComponent(
            String(target.relativePath.dropFirst())
        )
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            model.mountOrOpenDrive()
        }
        onClose()
    }
}

