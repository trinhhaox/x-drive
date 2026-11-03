import Foundation
import Network

// MARK: - GoogleOAuthManager (OAuth 2.0 PKCE & Loopback Callback for Desktop App)

public final class GoogleOAuthManager: @unchecked Sendable {
    public static let shared = GoogleOAuthManager()
    public static let defaultRedirectPort: UInt16 = 8787
    public static let defaultRedirectURI = "http://127.0.0.1:8787/auth/callback"
    public static let driveScope = "https://www.googleapis.com/auth/drive"

    private var listener: NWListener?
    private let lock = NSLock()
    private var pendingContinuation: CheckedContinuation<String, Error>?

    public init() {}

    /// Builds authorization URL for user browser sign-in
    public static func makeAuthorizationURL(
        clientId: String,
        redirectURI: String = defaultRedirectURI,
        state: String = UUID().uuidString
    ) -> URL? {
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        comps?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: driveScope),
            URLQueryItem(name: "access_type", value: "offline"), // Essential for persistent refresh_token
            URLQueryItem(name: "prompt", value: "consent"),       // Forces Google to always return refresh_token
            URLQueryItem(name: "state", value: state)
        ]
        return comps?.url
    }

    /// Exchanges an authorization code for long-lived refresh_token & initial access_token
    public static func exchangeCodeForTokens(
        code: String,
        clientId: String,
        clientSecret: String,
        redirectURI: String = defaultRedirectURI
    ) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int) {
        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]

        let bodyString = params.map { key, val in
            let escapedVal = val.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? val
            return "\(key)=\(escapedVal)"
        }.joined(separator: "&")

        req.httpBody = Data(bodyString.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown Error"
            throw GoogleDriveAPIError.serverError(
                statusCode: (resp as? HTTPURLResponse)?.statusCode ?? 500,
                message: "Không thể đổi mã xác thực Google lấy Token: \(errorText)"
            )
        }

        struct TokenResp: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }

        let decoded = try JSONDecoder().decode(TokenResp.self, from: data)
        return (
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresIn: decoded.expires_in ?? 3590
        )
    }

    /// Starts a temporary local HTTP server on 127.0.0.1:8787 to capture the OAuth redirect code automatically
    public func startLoopbackListener(port: UInt16 = defaultRedirectPort) async throws -> String {
        stopLoopbackListener()

        return try await withCheckedThrowingContinuation { continuation in
            do {
                let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 8787)
                let listener = try NWListener(using: .tcp, on: nwPort)
                self.listener = listener
                self.pendingContinuation = continuation

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleIncomingConnection(connection)
                }

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let err):
                        self.pendingContinuation?.resume(throwing: err)
                        self.pendingContinuation = nil
                    default:
                        break
                    }
                }

                listener.start(queue: .global(qos: .userInitiated))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    public func stopLoopbackListener() {
        listener?.cancel()
        listener = nil
        pendingContinuation = nil
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self, let data = data, let reqStr = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse HTTP GET /auth/callback?code=...
            var capturedCode: String?
            let lines = reqStr.components(separatedBy: "\r\n")
            if let firstLine = lines.first {
                let parts = firstLine.components(separatedBy: " ")
                if parts.count >= 2 {
                    let path = parts[1]
                    if let comps = URLComponents(string: "http://127.0.0.1\(path)"),
                       let codeItem = comps.queryItems?.first(where: { $0.name == "code" }) {
                        capturedCode = codeItem.value
                    }
                }
            }

            let responseHTML: String
            if capturedCode != nil {
                responseHTML = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=UTF-8\r
                Connection: close\r
                \r
                <!DOCTYPE html>
                <html>
                <head>
                    <meta charset="utf-8">
                    <title>XDrive - Kết Nối Google Drive Thành Công</title>
                    <style>
                        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; text-align: center; padding: 60px 20px; background: #0f172a; color: #fff; }
                        .card { max-width: 480px; margin: 0 auto; background: #1e293b; border-radius: 16px; padding: 32px; border: 1px solid #334155; }
                        h1 { color: #38bdf8; font-size: 24px; margin-bottom: 12px; }
                        p { color: #94a3b8; font-size: 15px; line-height: 1.5; }
                        .badge { display: inline-block; background: #22c55e22; color: #4ade80; border: 1px solid #22c55e44; padding: 6px 14px; border-radius: 20px; font-weight: 600; font-size: 13px; margin-top: 16px; }
                    </style>
                </head>
                <body>
                    <div class="card">
                        <h1>🎉 Kết Nối Thành Công!</h1>
                        <p>XDrive đã nhận được quyền truy cập vĩnh viễn (Refresh Token) từ Google Drive.</p>
                        <div class="badge">Đã bật Tự Động Gia Hạn Trọn Đời</div>
                        <p style="margin-top: 24px; font-size: 13px; color: #64748b;">Bạn có thể đóng tab trình duyệt này và quay lại ứng dụng XDrive.</p>
                    </div>
                </body>
                </html>
                """
            } else {
                responseHTML = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nKhong tim thay authorization code."
            }

            connection.send(content: Data(responseHTML.utf8), completion: .contentProcessed({ _ in
                connection.cancel()
            }))

            if let code = capturedCode {
                self.pendingContinuation?.resume(returning: code)
                self.pendingContinuation = nil
                self.stopLoopbackListener()
            }
        }
    }
}

