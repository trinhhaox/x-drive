import Foundation

public enum OrbitAPIError: Error, LocalizedError {
    case unauthorized
    case serverError(statusCode: Int, message: String)
    case invalidResponse
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Phiên đăng nhập đã hết hạn hoặc chưa xác thực."
        case .serverError(let code, let msg):
            return "Lỗi máy chủ (\(code)): \(msg)"
        case .invalidResponse:
            return "Phản hồi từ máy chủ không hợp lệ."
        case .notFound(let id):
            return "Không tìm thấy tài nguyên: \(id)"
        }
    }
}

// MARK: - OrbitAPI (Cloudflare Workers REST Client + WireRemote Conformance)

public final class OrbitAPI: WireRemote, @unchecked Sendable {
    public static let defaultBaseURLString = "https://xdrive-orbit-api.mr-trinhhao.workers.dev"

    public let baseURL: URL
    public let tokenStore: TokenStore
    public let governor: UploadGovernor
    private let session: URLSession
    private let lock = NSLock()
    private var urlCache: [String: (url: URL, expiresAt: Date)] = [:]

    public init(
        baseURL: URL? = nil,
        tokenStore: TokenStore = TokenStore(),
        governor: UploadGovernor = UploadGovernor()
    ) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let env = ProcessInfo.processInfo.environment["ORBIT_API_URL"], let u = URL(string: env) {
            self.baseURL = u
        } else {
            self.baseURL = URL(string: Self.defaultBaseURLString)!
        }
        self.tokenStore = tokenStore
        self.governor = governor
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Generic HTTP Helper

    private func authorizedRequest(path: String, method: String = "GET", queryItems: [URLQueryItem]? = nil, body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let tokens = tokenStore.load() {
            req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let start = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await session.data(for: request)
        let rttMs = (ProcessInfo.processInfo.systemUptime - start) * 1000.0
        governor.recordRTT(milliseconds: rttMs)

        guard let http = response as? HTTPURLResponse else {
            throw OrbitAPIError.invalidResponse
        }
        if http.statusCode == 401 {
            throw OrbitAPIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw OrbitAPIError.serverError(statusCode: http.statusCode, message: msg)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Authentication & User Profile

    public func signInWithBrowserCode(_ code: String, verifier: String, deviceName: String) async throws -> SessionResponse {
        let payload: [String: String] = [
            "code": code,
            "codeVerifier": verifier,
            "deviceName": deviceName
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = authorizedRequest(path: "auth/browser/exchange", method: "POST", body: body)
        let res = try await send(req, as: SessionResponse.self)
        tokenStore.save(accessToken: res.accessToken, refreshToken: res.refreshToken, userID: res.user.id)
        return res
    }

    public func refreshSession() async throws -> SessionResponse {
        guard let current = tokenStore.load() else {
            throw OrbitAPIError.unauthorized
        }
        let body = try JSONSerialization.data(withJSONObject: ["refreshToken": current.refreshToken])
        let req = authorizedRequest(path: "auth/refresh", method: "POST", body: body)
        let res = try await send(req, as: SessionResponse.self)
        tokenStore.save(accessToken: res.accessToken, refreshToken: res.refreshToken, userID: res.user.id)
        return res
    }

    public func me() async throws -> UserInfo {
        let req = authorizedRequest(path: "me")
        return try await send(req, as: UserInfo.self)
    }

    public func quota() async throws -> QuotaInfo {
        let req = authorizedRequest(path: "quota")
        return try await send(req, as: QuotaInfo.self)
    }

    public func updatePlan(limitBytes: Int64, planName: String) async throws {
        let payload: [String: Any] = [
            "limitBytes": limitBytes,
            "plan": planName
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = authorizedRequest(path: "user/plan", method: "POST", body: body)
        _ = try await session.data(for: req)
    }

    // MARK: - WireRemote & DriveRemote Conformance

    public func listDirectory(parentID: String?) async throws -> [FileItem] {
        var query: [URLQueryItem] = []
        if let parentID {
            query.append(URLQueryItem(name: "parentID", value: parentID))
        }
        let req = authorizedRequest(path: "files", queryItems: query.isEmpty ? nil : query)
        return try await send(req, as: [FileItem].self)
    }

    public func allFiles() async throws -> [FileItem] {
        let req = authorizedRequest(path: "files/all")
        return try await send(req, as: [FileItem].self)
    }

    public func changes(since cursor: Int64) async throws -> ChangePage {
        let req = authorizedRequest(
            path: "changes",
            queryItems: [URLQueryItem(name: "since", value: String(cursor))]
        )
        return try await send(req, as: ChangePage.self)
    }

    public func getItem(id: String) async throws -> FileItem {
        let req = authorizedRequest(path: "files/\(id)")
        return try await send(req, as: FileItem.self)
    }

    public func createDirectory(name: String, parentID: String?) async throws -> FileItem {
        try await createDirectoryWire(name: name, parentID: parentID, wire: nil)
    }

    public func createDirectoryWire(name: String, parentID: String?, wire: ZK.WireName?) async throws -> FileItem {
        var payload: [String: Any] = ["name": name]
        if let parentID { payload["parentID"] = parentID }
        if let wire {
            payload["encName"] = wire.encName
            payload["nameHash"] = wire.nameHash
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = authorizedRequest(path: "files/folder", method: "POST", body: body)
        return try await send(req, as: FileItem.self)
    }

    public func rename(id: String, newName: String, parentID: String?) async throws -> FileItem {
        try await renameWire(id: id, newName: newName, wire: nil)
    }

    public func renameWire(id: String, newName: String, wire: ZK.WireName?) async throws -> FileItem {
        var payload: [String: Any] = ["name": newName]
        if let wire {
            payload["encName"] = wire.encName
            payload["nameHash"] = wire.nameHash
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = authorizedRequest(path: "files/\(id)", method: "PATCH", body: body)
        return try await send(req, as: FileItem.self)
    }

    public func move(id: String, newParentID: String?, currentName: String) async throws -> FileItem {
        try await moveWire(id: id, newParentID: newParentID, wire: nil)
    }

    public func moveWire(id: String, newParentID: String?, wire: ZK.WireName?) async throws -> FileItem {
        var payload: [String: Any] = ["parentID": newParentID as Any]
        if let wire {
            payload["encName"] = wire.encName
            payload["nameHash"] = wire.nameHash
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = authorizedRequest(path: "files/\(id)", method: "PATCH", body: body)
        return try await send(req, as: FileItem.self)
    }

    public func delete(id: String) async throws {
        let req = authorizedRequest(path: "files/\(id)", method: "DELETE")
        _ = try await session.data(for: req)
    }

    public func updateTimestamps(id: String, createdAt: Date?, modifiedAt: Date?) async throws {
        var payload: [String: String] = [:]
        if let createdAt { payload["createdAt"] = createdAt.ISO8601Format() }
        if let modifiedAt { payload["modifiedAt"] = modifiedAt.ISO8601Format() }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = authorizedRequest(path: "files/\(id)", method: "PATCH", body: body)
        _ = try await session.data(for: req)
    }

    public func contentURL(id: String) async throws -> ContentURL {
        if let cached = lock.withLock({ urlCache[id] }), cached.expiresAt > Date() {
            return ContentURL(url: cached.url, expiresIn: Int(cached.expiresAt.timeIntervalSinceNow))
        }

        let req = authorizedRequest(path: "files/\(id)/content-url")
        let res = try await send(req, as: ContentURL.self)
        lock.withLock {
            urlCache[id] = (res.url, Date().addingTimeInterval(TimeInterval(max(10, res.expiresIn - 30))))
        }
        return res
    }

    public func fetchRange(remoteID: String, range: Range<UInt64>) async throws -> Data {
        let signed = try await contentURL(id: remoteID)
        var req = URLRequest(url: signed.url)
        req.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, _) = try await session.data(for: req)
        return data
    }

    public func uploadFile(
        existingRemoteID: String?,
        name: String,
        parentID: String?,
        source: BlobSource,
        createdAt: Date?,
        modifiedAt: Date?,
        onProgress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UploadResult {
        try await uploadFileWire(
            existingRemoteID: existingRemoteID,
            name: name,
            parentID: parentID,
            source: source,
            wire: nil,
            secrets: nil,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            onProgress: onProgress
        )
    }

    public func uploadFileWire(
        existingRemoteID: String?,
        name: String,
        parentID: String?,
        source: BlobSource,
        wire: ZK.WireName?,
        secrets: ZK.WireSecrets?,
        createdAt: Date?,
        modifiedAt: Date?,
        onProgress: (@Sendable (UInt64) -> Void)?
    ) async throws -> UploadResult {
        let total = source.totalSize
        var sent: UInt64 = 0
        var fullData = Data(capacity: Int(total))
        let step = 256 * 1024
        while sent < total {
            let chunkLen = Int(min(UInt64(step), total - sent))
            let slice = try source.readSlice(offset: sent, length: chunkLen)
            await governor.pacer.consume(bytes: slice.count)
            governor.recordBytesSent(slice.count)
            fullData.append(slice)
            sent += UInt64(slice.count)
            onProgress?(sent)
            if slice.isEmpty { break }
        }

        var query: [URLQueryItem] = [URLQueryItem(name: "name", value: name)]
        if let existingRemoteID { query.append(URLQueryItem(name: "id", value: existingRemoteID)) }
        if let parentID { query.append(URLQueryItem(name: "parentID", value: parentID)) }
        if let wire {
            query.append(URLQueryItem(name: "encName", value: wire.encName))
            query.append(URLQueryItem(name: "nameHash", value: wire.nameHash))
        }
        if let secrets {
            query.append(URLQueryItem(name: "fileKey", value: secrets.fileKey))
            query.append(URLQueryItem(name: "fileNonce", value: secrets.fileNonce))
            query.append(URLQueryItem(name: "plainSize", value: String(secrets.plainSize)))
        }

        var req = authorizedRequest(path: "files/upload", method: "POST", queryItems: query)
        req.httpBody = fullData
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return try await send(req, as: UploadResult.self)
    }

    // MARK: - Zero-Knowledge Privacy & Device Approval Endpoints

    public func privacyStatus() async throws -> PrivacyStatusResponse {
        let req = authorizedRequest(path: "privacy")
        return try await send(req, as: PrivacyStatusResponse.self)
    }

    public func enablePrivacy(keyCheck: String, dropPublic: String, dropPrivateWrap: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "keyCheck": keyCheck,
            "dropPublic": dropPublic,
            "dropPrivateWrap": dropPrivateWrap
        ])
        let req = authorizedRequest(path: "privacy/enable", method: "POST", body: body)
        _ = try await session.data(for: req)
    }

    public func unsealedFiles() async throws -> [UnsealedFile] {
        let req = authorizedRequest(path: "privacy/unsealed")
        return try await send(req, as: [UnsealedFile].self)
    }

    public func lockFileBatch(_ entries: [LockedFileEntry]) async throws {
        let body = try JSONEncoder().encode(entries)
        let req = authorizedRequest(path: "privacy/lock-batch", method: "POST", body: body)
        _ = try await session.data(for: req)
    }

    public func putEncryptedFileContent(id: String, source: BlobSource, secrets: ZK.WireSecrets) async throws {
        let cipherData = try source.readSlice(offset: 0, length: Int(source.totalSize))
        let query = [
            URLQueryItem(name: "fileKey", value: secrets.fileKey),
            URLQueryItem(name: "fileNonce", value: secrets.fileNonce),
            URLQueryItem(name: "plainSize", value: String(secrets.plainSize))
        ]
        var req = authorizedRequest(path: "files/\(id)/encrypted-content", method: "PUT", queryItems: query)
        req.httpBody = cipherData
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await session.data(for: req)
    }

    public func requestDeviceApproval(deviceName: String, publicKey: String) async throws -> DeviceApprovalRequest {
        let body = try JSONSerialization.data(withJSONObject: [
            "deviceName": deviceName,
            "publicKey": publicKey
        ])
        let req = authorizedRequest(path: "privacy/device-requests", method: "POST", body: body)
        return try await send(req, as: DeviceApprovalRequest.self)
    }

    public func pollDeviceApproval(id: String) async throws -> DeviceApprovalPollResponse {
        let req = authorizedRequest(path: "privacy/device-requests/\(id)")
        return try await send(req, as: DeviceApprovalPollResponse.self)
    }

    public func pendingDeviceApprovals() async throws -> [PendingDeviceApproval] {
        let req = authorizedRequest(path: "privacy/device-requests")
        return try await send(req, as: [PendingDeviceApproval].self)
    }

    public func approveDevice(id: String, grant: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["grant": grant])
        let req = authorizedRequest(path: "privacy/device-requests/\(id)/approve", method: "POST", body: body)
        _ = try await session.data(for: req)
    }

    public func rejectDevice(id: String) async throws {
        let req = authorizedRequest(path: "privacy/device-requests/\(id)/reject", method: "POST")
        _ = try await session.data(for: req)
    }

    // MARK: - Share Links & File Requests

    public func createShareLink(fileID: String) async throws -> ShareLinkItem {
        let body = try JSONSerialization.data(withJSONObject: ["fileID": fileID])
        let req = authorizedRequest(path: "shares", method: "POST", body: body)
        return try await send(req, as: ShareLinkItem.self)
    }

    public func createEncryptedShareLink(
        fileID: String,
        fileKey: String,
        fileNonce: String,
        encName: String,
        shareKeyWrap: String
    ) async throws -> ShareLinkItem {
        let body = try JSONSerialization.data(withJSONObject: [
            "fileID": fileID,
            "fileKey": fileKey,
            "fileNonce": fileNonce,
            "encName": encName,
            "shareKeyWrap": shareKeyWrap
        ])
        let req = authorizedRequest(path: "shares", method: "POST", body: body)
        return try await send(req, as: ShareLinkItem.self)
    }

    public func revokeShareLink(fileID: String) async throws {
        let req = authorizedRequest(path: "shares/\(fileID)", method: "DELETE")
        _ = try await session.data(for: req)
    }

    public func createFileRequest(folderID: String) async throws -> FileRequestInfo {
        let body = try JSONSerialization.data(withJSONObject: ["folderID": folderID])
        let req = authorizedRequest(path: "file-requests", method: "POST", body: body)
        return try await send(req, as: FileRequestInfo.self)
    }
}
