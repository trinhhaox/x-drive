import Cocoa


// MARK: - EjectWatcher (Monitors /Volumes/XDrive Mount & Unmount Events)

@MainActor
public final class EjectWatcher {
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    public init(onVolumeChange: @escaping @MainActor () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in onVolumeChange() }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in onVolumeChange() }
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let mountObserver { center.removeObserver(mountObserver) }
        if let unmountObserver { center.removeObserver(unmountObserver) }
    }
}

