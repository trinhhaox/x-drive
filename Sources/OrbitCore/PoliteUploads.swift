import Foundation

// MARK: - UploadLane & PoliteUploads (Bufferbloat-Aware Bandwidth Controller)

public enum UploadLane: String, Sendable {
    case small
    case big
}

public final class UploadPacer: @unchecked Sendable {
    private let lock = NSLock()
    private var rateBytesPerSec: UInt64 // 0 = unlimited
    private var nextAllowedTime: TimeInterval = 0

    public init(rateBytesPerSec: UInt64 = 0) {
        self.rateBytesPerSec = rateBytesPerSec
    }

    public func setRate(bytesPerSec: UInt64) {
        lock.lock()
        self.rateBytesPerSec = bytesPerSec
        lock.unlock()
    }

    public func currentRate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return rateBytesPerSec
    }

    public func consume(bytes: Int) async {
        let delaySeconds: TimeInterval = {
            lock.lock()
            defer { lock.unlock() }
            guard rateBytesPerSec > 0, bytes > 0 else { return 0 }
            let now = ProcessInfo.processInfo.systemUptime
            let duration = Double(bytes) / Double(rateBytesPerSec)
            let start = max(now, nextAllowedTime)
            nextAllowedTime = start + duration
            return max(0, start - now)
        }()
        if delaySeconds > 0.001 {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
    }
}

public final class UploadGovernor: @unchecked Sendable {
    public static let minRateBytesPerSec: UInt64 = 256 * 1024       // 256 KiB/s floor
    public static let maxRateBytesPerSec: UInt64 = 64 * 1024 * 1024 // 64 MiB/s ceiling
    public static let defaultInitialRate: UInt64 = 8 * 1024 * 1024  // 8 MiB/s initial

    private let lock = NSLock()
    public let pacer: UploadPacer
    private var enabled: Bool
    private var baselineMs: Double = 25.0
    private var smoothedMs: Double = 25.0
    private var _throttling: Bool = false
    private var _workers: Int = 4
    private var bytesWindow: [(time: TimeInterval, bytes: Int)] = []

    public init(enabled: Bool = true) {
        self.enabled = enabled
        self.pacer = UploadPacer(rateBytesPerSec: enabled ? Self.defaultInitialRate : 0)
    }

    public var isThrottling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && _throttling
    }

    public var recommendedWorkers: Int {
        lock.lock()
        defer { lock.unlock() }
        return enabled ? _workers : 6
    }

    public func setPoliteEnabled(_ polite: Bool) {
        lock.lock()
        self.enabled = polite
        if !polite {
            _throttling = false
            _workers = 6
        }
        lock.unlock()
        pacer.setRate(bytesPerSec: polite ? Self.defaultInitialRate : 0)
    }

    public func recordRTT(milliseconds rttMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard rttMs > 0 else { return }
        if rttMs < baselineMs || baselineMs <= 0 {
            baselineMs = rttMs
        } else {
            baselineMs = baselineMs * 0.995 + rttMs * 0.005
        }
        smoothedMs = smoothedMs * 0.7 + rttMs * 0.3

        guard enabled else {
            _throttling = false
            return
        }

        let bloatDelta = smoothedMs - baselineMs
        var current = pacer.currentRate()
        if current == 0 { current = Self.defaultInitialRate }

        if bloatDelta > 35.0 {
            // Congestion detected ("Uploading gently so your internet stays fast")
            let reduced = max(Self.minRateBytesPerSec, UInt64(Double(current) * 0.7))
            pacer.setRate(bytesPerSec: reduced)
            _throttling = true
            _workers = max(1, _workers - 1)
        } else if bloatDelta < 12.0 {
            // Network is uncongested, gently ramp up
            let increased = min(Self.maxRateBytesPerSec, UInt64(Double(current) * 1.15))
            pacer.setRate(bytesPerSec: increased)
            _throttling = false
            _workers = min(6, _workers + 1)
        }
    }

    public func recordBytesSent(_ bytes: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        bytesWindow.append((now, bytes))
        bytesWindow.removeAll { now - $0.time > 3.0 }
        lock.unlock()
    }

    public func currentThroughputBytesPerSec() -> UInt64 {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        bytesWindow.removeAll { now - $0.time > 3.0 }
        guard !bytesWindow.isEmpty else { return 0 }
        let sum = bytesWindow.reduce(0) { $0 + $1.bytes }
        return UInt64(Double(sum) / 3.0)
    }
}

