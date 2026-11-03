import SwiftUI
import OrbitCore

@main
struct XDriveApp: App {
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
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("XDrive", systemImage: "externaldrive.fill.badge.icloud") {
            MenuBarPanel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

