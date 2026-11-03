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
        appVersion: String = "0.3.15",
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

    /// Uploads queued diagnostic & crash reports to the backend endpoint `POST /api/error-reports`
    public func uploadReports(to baseURL: URL, token: String? = nil) async throws -> Int {
        let reports = latestReports()
        guard !reports.isEmpty else { return 0 }

        let endpoint = baseURL.appendingPathComponent("api/error-reports")
        var sentCount = 0

        for report in reports {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let body: [String: Any] = [
                "id": report.id,
                "component": report.component,
                "code": report.code,
                "message": report.message,
                "appVersion": report.appVersion,
                "osVersion": report.osVersion,
                "details": report.details
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { continue }
            request.httpBody = jsonData

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    sentCount += 1
                }
            } catch {
                // If network fails, stop loop and preserve unsent reports
                break
            }
        }
        return sentCount
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

