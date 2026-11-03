import Foundation
import Security
import CryptoKit

// MARK: - Shared App Group Container

public enum SharedContainer {
    public static let appGroupIdentifier = "VN5T9LGLT3.com.letcontactabhi.orbit"
    public static let keychainAccessGroup = "VN5T9LGLT3.com.letcontactabhi.orbit.shared"
    public static let refreshDirectoryName = "._helumi-refresh"

    public static var overrideDirectory: URL?

    public static var containerURL: URL {
        if let overrideDirectory {
            try? FileManager.default.createDirectory(at: overrideDirectory, withIntermediateDirectories: true)
            return overrideDirectory
        }
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return groupURL
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/XDrive", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    public static var driveDirectory: URL {
        let url = containerURL.appendingPathComponent("Drive", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var treeFile: URL {
        driveDirectory.appendingPathComponent("tree-snapshot.json")
    }

    public static var statusFile: URL {
        containerURL.appendingPathComponent("drive-status.json")
    }

    public static var cacheSettingsFile: URL {
        containerURL.appendingPathComponent("cache-settings.json")
    }

    public static var uploadSettingsFile: URL {
        containerURL.appendingPathComponent("upload-settings.json")
    }

    public static var keepOnThisMacFile: URL {
        containerURL.appendingPathComponent("keep-on-this-mac.json")
    }

    public static var stoppedUploadsFile: URL {
        containerURL.appendingPathComponent("stopped-uploads.json")
    }

    public static var clearCacheRequestFile: URL {
        containerURL.appendingPathComponent("clear-cache.request")
    }

    public static var refreshRequestsDirectory: URL {
        let url = containerURL.appendingPathComponent("RefreshRequests", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Status & Settings Persistence

    public static func writeDriveStatus(_ status: DriveStatusSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status) {
            try? data.write(to: statusFile, options: .atomic)
        }
    }

    public static func readDriveStatus() -> DriveStatusSnapshot? {
        guard let data = try? Data(contentsOf: statusFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DriveStatusSnapshot.self, from: data)
    }

    public static func writeCacheSettings(_ settings: CacheSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: cacheSettingsFile, options: .atomic)
        }
    }

    public static func readCacheSettings() -> CacheSettings {
        guard let data = try? Data(contentsOf: cacheSettingsFile),
              let decoded = try? JSONDecoder().decode(CacheSettings.self, from: data) else {
            return CacheSettings()
        }
        return decoded
    }

    public static func writeUploadSettings(_ settings: UploadSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: uploadSettingsFile, options: .atomic)
        }
    }

    public static func readUploadSettings() -> UploadSettings {
        guard let data = try? Data(contentsOf: uploadSettingsFile),
              let decoded = try? JSONDecoder().decode(UploadSettings.self, from: data) else {
            return UploadSettings(polite: true)
        }
        return decoded
    }

    public static func readPinnedRemoteIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: keepOnThisMacFile),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    public static func setPinned(remoteID: String, pinned: Bool) {
        var current = readPinnedRemoteIDs()
        if pinned {
            current.insert(remoteID)
        } else {
            current.remove(remoteID)
        }
        if let data = try? JSONEncoder().encode(Array(current).sorted()) {
            try? data.write(to: keepOnThisMacFile, options: .atomic)
        }
    }

    public static func requestDriveRefresh(remoteID: String? = nil) {
        let token = remoteID ?? "all"
        let marker = refreshRequestsDirectory.appendingPathComponent(token)
        try? Data(Date().ISO8601Format().utf8).write(to: marker, options: .atomic)
    }

    public static func consumeRefreshRequests() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: refreshRequestsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var ids: [String] = []
        for url in items {
            ids.append(url.lastPathComponent)
            try? FileManager.default.removeItem(at: url)
        }
        return ids
    }
}

// MARK: - TokenStore & KeychainSecretStore

public protocol SecretStore: Sendable {
    func load(account: String) -> Data?
    func save(_ data: Data, account: String) -> Bool
    func delete(account: String)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func load(account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public func save(_ data: Data, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = data
        return true
    }

    public func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    private let synchronizable: Bool
    private let fallback = InMemorySecretStore()

    public static let local = KeychainSecretStore(service: "com.letcontactabhi.orbit.keys", synchronizable: false)
    public static let icloud = KeychainSecretStore(service: "com.letcontactabhi.orbit.keys.icloud", synchronizable: true)

    public init(service: String, synchronizable: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
    }

    public func load(account: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return data
        }
        return fallback.load(account: account)
    }

    public func save(_ data: Data, account: String) -> Bool {
        _ = fallback.save(data, account: account)
        deleteKeychainOnly(account: account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess || fallback.load(account: account) != nil
    }

    public func delete(account: String) {
        fallback.delete(account: account)
        deleteKeychainOnly(account: account)
    }

    private func deleteKeychainOnly(account: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        SecItemDelete(query as CFDictionary)
    }
}

public final class TokenStore: @unchecked Sendable {
    public struct StoredTokens: Codable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String
        public var userID: String?

        public init(accessToken: String, refreshToken: String, userID: String? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.userID = userID
        }
    }

    private let store: SecretStore
    private let accountKey = "session_tokens"

    public init(store: SecretStore = KeychainSecretStore(service: "com.letcontactabhi.orbit.session")) {
        self.store = store
    }

    public func save(accessToken: String, refreshToken: String, userID: String? = nil) {
        let tokens = StoredTokens(accessToken: accessToken, refreshToken: refreshToken, userID: userID)
        if let data = try? JSONEncoder().encode(tokens) {
            _ = store.save(data, account: accountKey)
        }
    }

    public func load() -> StoredTokens? {
        guard let data = store.load(account: accountKey) else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    public func clear() {
        store.delete(account: accountKey)
    }
}

// MARK: - KeyManager (Zero-Knowledge Master Key Lifecycle)

public final class KeyManager: @unchecked Sendable {
    private let lock = NSLock()
    private let localStore: SecretStore
    private let cloudStore: SecretStore
    private var _state: PrivacyState = .off
    private var _masterKey: SymmetricKey?
    private var _userID: String?
    private var _dropPublic: String?
    private var _dropPrivateWrap: String?

    public init(
        localStore: SecretStore = KeychainSecretStore.local,
        cloudStore: SecretStore = KeychainSecretStore.icloud
    ) {
        self.localStore = localStore
        self.cloudStore = cloudStore
    }

    public var state: PrivacyState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public var keys: ZK.AccountKeys? {
        lock.lock()
        defer { lock.unlock() }
        if case .unlocked(let accountKeys) = _state {
            return accountKeys
        }
        return nil
    }

    public var masterKey: SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return _masterKey
    }

    public var dropPublic: String? {
        lock.lock()
        defer { lock.unlock() }
        return _dropPublic
    }

    public var dropPrivateWrap: String? {
        lock.lock()
        defer { lock.unlock() }
        return _dropPrivateWrap
    }

    public func configure(userID: String, serverStatus: PrivacyStatusResponse) {
        lock.lock()
        defer { lock.unlock() }
        self._userID = userID
        self._dropPublic = serverStatus.dropPublic
        self._dropPrivateWrap = serverStatus.dropPrivateWrap

        guard serverStatus.enabled, let keyCheck = serverStatus.keyCheck else {
            self._state = .off
            self._masterKey = nil
            return
        }

        // Try loading master key from local store or iCloud store
        if let raw = localStore.load(account: userID) ?? cloudStore.load(account: userID) {
            let candidate = SymmetricKey(data: raw)
            let derived = ZK.deriveKeys(from: candidate)
            if ZK.verifyKeyCheck(keyCheck, keys: derived) {
                self._masterKey = candidate
                self._state = .unlocked(derived)
                return
            }
        }
        self._state = .locked
    }

    public func setupNewMasterKey(for userID: String) throws -> (
        master: SymmetricKey,
        keys: ZK.AccountKeys,
        keyCheck: String,
        dropPublic: String,
        dropPrivateWrap: String,
        recoveryCode: String
    ) {
        let master = ZK.newMasterKey()
        let derived = ZK.deriveKeys(from: master)
        let keyCheck = try ZK.makeKeyCheck(derived)
        let dropPair = try ZK.newDropKeyPair(keys: derived)
        let recovery = ZK.packRecovery(master)

        let raw = master.withUnsafeBytes { Data($0) }
        _ = localStore.save(raw, account: userID)
        _ = cloudStore.save(raw, account: userID)

        lock.lock()
        self._userID = userID
        self._masterKey = master
        self._dropPublic = dropPair.publicKey
        self._dropPrivateWrap = dropPair.wrappedPrivateKey
        self._state = .unlocked(derived)
        lock.unlock()

        return (master, derived, keyCheck, dropPair.publicKey, dropPair.wrappedPrivateKey, recovery)
    }

    public func unlock(recoveryCode: String, expectedKeyCheck: String?) throws -> ZK.AccountKeys {
        let master = try ZK.unpackRecovery(recoveryCode)
        return try acceptMasterKey(master, expectedKeyCheck: expectedKeyCheck)
    }

    public func acceptMasterKey(_ master: SymmetricKey, expectedKeyCheck: String?) throws -> ZK.AccountKeys {
        let derived = ZK.deriveKeys(from: master)
        if let expectedKeyCheck, !ZK.verifyKeyCheck(expectedKeyCheck, keys: derived) {
            throw ZKError.invalidKeyCheck
        }
        let raw = master.withUnsafeBytes { Data($0) }
        lock.lock()
        let uid = _userID ?? "default"
        _masterKey = master
        _state = .unlocked(derived)
        lock.unlock()

        _ = localStore.save(raw, account: uid)
        _ = cloudStore.save(raw, account: uid)
        return derived
    }

    public func recoveryCode() -> String? {
        lock.lock()
        guard let master = _masterKey else {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return ZK.packRecovery(master)
    }

    public func setMigrating(_ progress: SweepProgress?) {
        lock.lock()
        defer { lock.unlock() }
        if let progress {
            _state = .migrating(progress)
        } else if let master = _masterKey {
            _state = .unlocked(ZK.deriveKeys(from: master))
        }
    }

    public func lockSession() {
        lock.lock()
        defer { lock.unlock() }
        if let uid = _userID {
            localStore.delete(account: uid)
        }
        _masterKey = nil
        _state = .locked
    }
}

