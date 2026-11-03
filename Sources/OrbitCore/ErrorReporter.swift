import Foundation
import MetricKit

// MARK: - ErrorReportPayload & ErrorReporter

public struct ErrorReportPayload: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var component: String
    public var code: String
    public var message: String
    public var appVersion: String
    public var osVersion: String
    public var details: [String: String]

    public init(
        id: String = UUID().uuidString,
        component: String,
        code: String = "diagnostic",
        message: String,
        appVersion: String = "0.3.13",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.component = component
        self.code = code
        self.message = message
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.details = details
    }
}

public final class ErrorReporter: @unchecked Sendable {
    public static let shared = ErrorReporter()
    private let lock = NSLock()
    private var recentReports: [ErrorReportPayload] = []

    public init() {}

    public func report(component: String, code: String = "diagnostic", message: String, details: [String: String] = [:]) {
        let payload = ErrorReportPayload(
            component: component,
            code: code,
            message: message,
            details: details
        )
        lock.withLock {
            recentReports.insert(payload, at: 0)
            if recentReports.count > 50 {
                recentReports = Array(recentReports.prefix(50))
            }
        }
    }

    public func latestReports() -> [ErrorReportPayload] {
        lock.withLock { recentReports }
    }

    public func clearQueue() {
        lock.withLock { recentReports.removeAll() }
    }
}

// MARK: - CrashReports (Apple MetricKit MXMetricManagerSubscriber)

public final class CrashReports: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = CrashReports()

    public override init() {
        super.init()
    }

    public func start() {
        MXMetricManager.shared.add(self)
    }

    public func stop() {
        MXMetricManager.shared.remove(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let jsonStr = String(data: payload.jsonRepresentation(), encoding: .utf8) ?? "{}"
            ErrorReporter.shared.report(
                component: "MetricKit",
                code: "diagnostic_payload",
                message: "Received MXDiagnosticPayload",
                details: ["payload_preview": String(jsonStr.prefix(512))]
            )
        }
    }
}

// MARK: - ShareMaker (Zero-Knowledge E2EE Share Links & File Requests)

public enum ShareMaker {
    /// Generates an end-to-end encrypted share link where the 128-bit `shareKey` is placed in the URL fragment (`#sk=...`)
    /// so the backend server never sees the decryption key.
    public static func makeEncryptedShareURL(
        baseShareURL: URL,
        secrets: ZK.FileSecrets,
        fileName: String,
        accountKeys: ZK.AccountKeys
    ) throws -> (
        fullShareURL: URL,
        wrappedFileKey: String,
        fileNonce: String,
        encName: String,
        shareKeyWrap: String
    ) {
        let pkg = try ZK.makeShare(secrets: secrets, fileName: fileName, accountKeys: accountKeys)
        var components = URLComponents(url: baseShareURL, resolvingAgainstBaseURL: false)!
        components.fragment = "sk=\(pkg.shareKeyB64)"
        let finalURL = components.url ?? baseShareURL
        return (
            fullShareURL: finalURL,
            wrappedFileKey: pkg.wrappedFileKey,
            fileNonce: pkg.fileNonce,
            encName: pkg.encName,
            shareKeyWrap: pkg.shareKeyWrap
        )
    }
}

