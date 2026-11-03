import AppKit
import SwiftUI
@preconcurrency import UserNotifications
import OrbitCore

// MARK: - StatusItemDropView (Drag & Drop directly onto macOS Menu Bar icon)

public final class StatusItemDropView: NSView {
    private var isReceivingDrag = false {
        didSet { needsDisplay = true }
    }
    public var onFilesDropped: (([URL]) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if extractFileURLs(from: sender).isEmpty {
            return []
        }
        isReceivingDrag = true
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        isReceivingDrag = false
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !extractFileURLs(from: sender).isEmpty
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isReceivingDrag = false
        let urls = extractFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isReceivingDrag else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4)
        path.fill()
    }

    private func extractFileURLs(from info: NSDraggingInfo) -> [URL] {
        let pasteboard = info.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else {
            return []
        }
        return urls
    }
}

// MARK: - DeviceNotifier (Background E2EE Device Approval Monitor)

@MainActor
public final class DeviceNotifier: ObservableObject {
    @Published public private(set) var activeRequest: PendingDeviceApproval?
    @Published public private(set) var matchCode: String = ""

    private var timerTask: Task<Void, Never>?

    public init() {}

    public func presentApprovalSheet(for request: PendingDeviceApproval) {
        self.matchCode = ZK.matchCode(deviceID: request.id, publicKey: request.publicKey)
        self.activeRequest = request
        postSystemNotificationIfPermitted(for: request, code: self.matchCode)
    }

    public func dismiss() {
        self.activeRequest = nil
        self.matchCode = ""
    }

    private func postSystemNotificationIfPermitted(for request: PendingDeviceApproval, code: String) {
        // Guard against CLI test runners without a bundle identifier
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Yêu cầu Phê duyệt Thiết bị E2EE Mới"
            content.body = "\(request.deviceName) muốn truy cập kho khóa Zero-Knowledge. Mã đối chiếu: \(code)"
            content.sound = .default

            let req = UNNotificationRequest(
                identifier: "orbit.device.\(request.id)",
                content: content,
                trigger: nil
            )
            center.add(req)
        }
    }
}

// MARK: - AllowDeviceSheet (Interactive 6-Digit ECDH Match Code Modal)

public struct AllowDeviceSheet: View {
    @ObservedObject var model: AppModel
    let request: PendingDeviceApproval

    public init(model: AppModel, request: PendingDeviceApproval) {
        self.model = model
        self.request = request
    }

    public var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 42))
                .foregroundStyle(.blue)

            Text("Phê duyệt Thiết bị Mới (ECDH P-256)")
                .font(.title2.bold())

            Text("Thiết bị **\(request.deviceName)** đang yêu cầu quyền giải mã Zero-Knowledge. Hãy kiểm tra mã đối chiếu 6 chữ số hiển thị trên thiết bị đó:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // 6-Digit Match Code Box (`ZK.matchCode(deviceID:publicKey:)`)
            Text(ZK.matchCode(deviceID: request.id, publicKey: request.publicKey))
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .tracking(4)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.blue.opacity(0.35), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("ID Yêu cầu: \(request.id)")
                Text("Khóa công khai P-256: \(request.publicKey.prefix(28))...")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Button("Từ chối") {
                    model.rejectPendingDevice(request)
                }
                .buttonStyle(.bordered)

                Button("Mã khớp — Cấp khóa ECDH") {
                    model.approvePendingDevice(request)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 460)
    }
}

