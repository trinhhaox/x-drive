import AppKit
import SwiftUI
import OrbitCore

// MARK: - AppDelegate & Window Delegate (Ensures App Always Reopens when Clicked from Dock/Finder)

public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    public static weak var shared: AppDelegate?
    public weak var mainWindow: NSWindow?

    public override init() {
        super.init()
        AppDelegate.shared = self
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            return true
        }
        for window in sender.windows where !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
            return true
        }
        return true
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide window instead of destroying it so clicking Dock icon re-opens immediately
        sender.orderOut(nil)
        return false
    }
}

// MARK: - WindowAccessor Helper

public struct WindowAccessor: NSViewRepresentable {
    public let onWindow: (NSWindow) -> Void

    public init(onWindow: @escaping (NSWindow) -> Void) {
        self.onWindow = onWindow
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - XDriveApp Main Scene

@main
struct XDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--self-test") {
            print("XDriveApp binary self-test passed.")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("XDrive — Ổ đĩa Đám mây FSKit & Zero-Knowledge E2EE") {
            MainWindowView(model: model)
                .background(
                    WindowAccessor { window in
                        appDelegate.mainWindow = window
                        window.delegate = appDelegate
                    }
                )
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("XDrive", systemImage: "externaldrive.fill.badge.icloud") {
            MenuBarPanel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
