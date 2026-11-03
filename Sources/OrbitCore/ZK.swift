import Foundation
import CryptoKit

public enum ZKError: Error, LocalizedError, Equatable {
    case invalidCiphertext
    case invalidRecoveryCode
    case invalidKeyCheck
    case invalidPublicKey
    case integrityFailure
    case missingFileSecrets

    public var errorDescription: String? {
        switch self {
        case .invalidCiphertext:
            return "Dữ liệu mã hóa không hợp lệ hoặc bị hỏng."
        case .invalidRecoveryCode:
            return "Mã khôi phục (Recovery Code) không đúng định dạng hoặc sai checksum."
        case .invalidKeyCheck:
            return "Khóa giải mã không khớp với tài khoản này."
        case .invalidPublicKey:
            return "Khóa công khai P-256 không hợp lệ."
        case .integrityFailure:
            return "Xác thực toàn vẹn khối dữ liệu (AES-GCM tag) thất bại."
        case .missingFileSecrets:
            return "Thiếu siêu dữ liệu khóa tệp (WireSecrets)."
        }
    }
}

public enum ZK {
    // Reconstructed exact constants from OrbitCore.ZK (VMA 0x100132ad0 - 0x100132ae0)
    public static let piece: Int = 1_048_576       // 1 MiB plaintext per piece
    public static let tag: Int = 16                // 16-byte AES-GCM authentication tag
    public static let shareKeyBytes: Int = 16      // 16-byte (128-bit) share key

    private static let keyCheckDomain = Data("helumi key check v1".utf8)
    private static let wrapDomain = Data("helumi wrap v1".utf8)
    private static let nameDomain = Data("helumi name v1".utf8)
    private static let nameIndexDomain = Data("helumi name-index v1".utf8)
    private static let recoveryDomain = Data("helumi recovery v1".utf8)
    private static let deviceDomain = Data("helumi device v1".utf8)
    private static let dropDomain = Data("helumi drop v1".utf8)

    // MARK: - Key Types

    public struct AccountKeys: Equatable, Sendable {
        public let wrap: SymmetricKey
        public let name: SymmetricKey
        public let nameIndex: SymmetricKey

        public init(wrap: SymmetricKey, name: SymmetricKey, nameIndex: SymmetricKey) {
            self.wrap = wrap
            self.name = name
            self.nameIndex = nameIndex
        }

        public static func == (lhs: AccountKeys, rhs: AccountKeys) -> Bool {
            lhs.wrap.withUnsafeBytes { Data($0) } == rhs.wrap.withUnsafeBytes { Data($0) } &&
            lhs.name.withUnsafeBytes { Data($0) } == rhs.name.withUnsafeBytes { Data($0) } &&
            lhs.nameIndex.withUnsafeBytes { Data($0) } == rhs.nameIndex.withUnsafeBytes { Data($0) }
        }
    }

    public struct FileSecrets: Equatable, Sendable {
        public let key: SymmetricKey
        public let nonce: Data // 8-byte base nonce prefix (combined with 4-byte piece index -> 12-byte GCM nonce)

        public init(key: SymmetricKey, nonce: Data) {
            self.key = key
            self.nonce = nonce
        }

        public static func == (lhs: FileSecrets, rhs: FileSecrets) -> Bool {
            lhs.key.withUnsafeBytes { Data($0) } == rhs.key.withUnsafeBytes { Data($0) } &&
            lhs.nonce == rhs.nonce
        }
    }

    public struct WireSecrets: Codable, Equatable, Sendable {
        public var fileKey: String
        public var fileNonce: String
        public var plainSize: Int64

        public init(fileKey: String, fileNonce: String, plainSize: Int64) {
            self.fileKey = fileKey
            self.fileNonce = fileNonce
            self.plainSize = plainSize
        }
    }

    public struct WireName: Codable, Equatable, Sendable {
        public var encName: String
        public var nameHash: String

        public init(encName: String, nameHash: String) {
            self.encName = encName
            self.nameHash = nameHash
        }
    }

    // MARK: - Master Key & Key Derivation

    public static func newMasterKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func deriveKeys(from master: SymmetricKey) -> AccountKeys {
        let wrap = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            info: wrapDomain,
            outputByteCount: 32
        )
        let name = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            info: nameDomain,
            outputByteCount: 32
        )
        let nameIndex = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            info: nameIndexDomain,
            outputByteCount: 32
        )
        return AccountKeys(wrap: wrap, name: name, nameIndex: nameIndex)
    }

    public static func makeKeyCheck(_ keys: AccountKeys) throws -> String {
        let sealed = try AES.GCM.seal(keyCheckDomain, using: keys.wrap)
        guard let combined = sealed.combined else {
            throw ZKError.invalidCiphertext
        }
        return base64URLEncode(combined)
    }

    public static func verifyKeyCheck(_ check: String, keys: AccountKeys) -> Bool {
        guard let raw = base64URLDecode(check),
              let box = try? AES.GCM.SealedBox(combined: raw),
              let opened = try? AES.GCM.open(box, using: keys.wrap) else {
            return false
        }
        return opened == keyCheckDomain
    }

    // MARK: - File Name Encryption & Blind Indexing

    public static func nameHash(_ plain: String, parentID: String?, keys: AccountKeys) -> String {
        let normalized = plain.precomposedStringWithCanonicalMapping.lowercased()
        let context = "\(parentID ?? "root"):\(normalized)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(context.utf8), using: keys.nameIndex)
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func lockName(_ plain: String, parentID: String?, keys: AccountKeys) throws -> WireName {
        let sealed = try AES.GCM.seal(Data(plain.utf8), using: keys.name)
        guard let combined = sealed.combined else {
            throw ZKError.invalidCiphertext
        }
        let encName = "e1:" + base64URLEncode(combined)
        let hash = nameHash(plain, parentID: parentID, keys: keys)
        return WireName(encName: encName, nameHash: hash)
    }

    public static func unlockName(_ encName: String, keys: AccountKeys) throws -> String {
        let payload = encName.hasPrefix("e1:") ? String(encName.dropFirst(3)) : encName
        guard let raw = base64URLDecode(payload) else {
            throw ZKError.invalidCiphertext
        }
        let box = try AES.GCM.SealedBox(combined: raw)
        let plainData = try AES.GCM.open(box, using: keys.name)
        guard let str = String(data: plainData, encoding: .utf8) else {
            throw ZKError.invalidCiphertext
        }
        return str
    }

    // MARK: - File Secrets & Piece-Level Content Encryption

    public static func newFileSecrets() -> FileSecrets {
        var nonceBytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        return FileSecrets(key: SymmetricKey(size: .bits256), nonce: Data(nonceBytes))
    }

    public static func wrapFileSecrets(_ secrets: FileSecrets, plainSize: UInt64, with keys: AccountKeys) throws -> WireSecrets {
        let rawKey = secrets.key.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(rawKey, using: keys.wrap)
        guard let combined = sealed.combined else {
            throw ZKError.invalidCiphertext
        }
        return WireSecrets(
            fileKey: base64URLEncode(combined),
            fileNonce: base64URLEncode(secrets.nonce),
            plainSize: Int64(plainSize)
        )
    }

    public static func unwrapFileSecrets(_ wire: WireSecrets, with keys: AccountKeys) throws -> (FileSecrets, UInt64) {
        guard let wrappedKey = base64URLDecode(wire.fileKey),
              let nonce = base64URLDecode(wire.fileNonce),
              nonce.count == 8 else {
            throw ZKError.invalidCiphertext
        }
        let box = try AES.GCM.SealedBox(combined: wrappedKey)
        let rawKey = try AES.GCM.open(box, using: keys.wrap)
        let secrets = FileSecrets(key: SymmetricKey(data: rawKey), nonce: nonce)
        return (secrets, UInt64(max(0, wire.plainSize)))
    }

    public static func pieceCount(plainSize: UInt64) -> Int {
        if plainSize == 0 { return 1 }
        return Int((plainSize + UInt64(piece) - 1) / UInt64(piece))
    }

    public static func cipherSize(plainSize: UInt64) -> UInt64 {
        let count = UInt64(pieceCount(plainSize: plainSize))
        return plainSize + count * UInt64(tag)
    }

    public static func plainRange(
        offset: UInt64,
        length: Int,
        plainSize: UInt64
    ) -> (firstPiece: Int, lastPiece: Int, cipherOffset: UInt64, cipherLength: Int) {
        if plainSize == 0 || length <= 0 || offset >= plainSize {
            return (0, 0, 0, Int(cipherSize(plainSize: 0)))
        }
        let clampedEnd = min(plainSize, offset + UInt64(length))
        let firstPiece = Int(offset / UInt64(piece))
        let lastPiece = Int((clampedEnd - 1) / UInt64(piece))
        let cipherPieceSize = UInt64(piece + tag)
        let cipherOffset = UInt64(firstPiece) * cipherPieceSize

        let totalPieces = pieceCount(plainSize: plainSize)
        var totalCipherLen = 0
        for p in firstPiece...lastPiece {
            let isLast = (p == totalPieces - 1)
            if isLast {
                let rem = Int(plainSize - UInt64(p * piece))
                totalCipherLen += rem + tag
            } else {
                totalCipherLen += piece + tag
            }
        }
        return (firstPiece, lastPiece, cipherOffset, totalCipherLen)
    }

    private static func makePieceNonce(base: Data, index: Int) throws -> AES.GCM.Nonce {
        var bytes = Data(base.prefix(8))
        var idxBE = UInt32(index).bigEndian
        withUnsafeBytes(of: &idxBE) { bytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: bytes)
    }

    private static func makePieceAAD(index: Int, last: Bool) -> Data {
        var aad = Data( capacity: 5)
        var idxBE = UInt32(index).bigEndian
        withUnsafeBytes(of: &idxBE) { aad.append(contentsOf: $0) }
        aad.append(last ? 1 : 0)
        return aad
    }

    public static func lockPiece(_ plain: Data, index: Int, last: Bool, secrets: FileSecrets) throws -> Data {
        let nonce = try makePieceNonce(base: secrets.nonce, index: index)
        let aad = makePieceAAD(index: index, last: last)
        let sealed = try AES.GCM.seal(plain, using: secrets.key, nonce: nonce, authenticating: aad)
        var out = Data(capacity: plain.count + tag)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    public static func unlockPiece(_ cipher: Data, index: Int, last: Bool, secrets: FileSecrets) throws -> Data {
        guard cipher.count >= tag else {
            throw ZKError.invalidCiphertext
        }
        let nonce = try makePieceNonce(base: secrets.nonce, index: index)
        let aad = makePieceAAD(index: index, last: last)
        let ct = cipher.prefix(cipher.count - tag)
        let tagData = cipher.suffix(tag)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tagData)
        do {
            return try AES.GCM.open(box, using: secrets.key, authenticating: aad)
        } catch {
            throw ZKError.integrityFailure
        }
    }

    // MARK: - Recovery Code (Human-Readable Base32 with Checksum)

    private static let base32Alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func packRecovery(_ master: SymmetricKey) -> String {
        let raw = master.withUnsafeBytes { Data($0) }
        let mac = HMAC<SHA256>.authenticationCode(for: raw, using: SymmetricKey(data: recoveryDomain))
        var payload = Data(raw)
        payload.append(contentsOf: Data(mac).prefix(3)) // 32 + 3 = 35 bytes = 280 bits = 56 Base32 chars

        var bits = 0
        var value = 0
        var chars: [Character] = []
        for byte in payload {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let idx = (value >> bits) & 0x1F
                chars.append(base32Alphabet[idx])
            }
        }
        // Group into 7 blocks of 8 characters separated by "-"
        var groups: [String] = []
        for i in stride(from: 0, to: chars.count, by: 8) {
            let end = min(i + 8, chars.count)
            groups.append(String(chars[i..<end]))
        }
        return groups.joined(separator: "-")
    }

    public static func unpackRecovery(_ code: String) throws -> SymmetricKey {
        let cleaned = code.uppercased().filter { base32Alphabet.contains($0) }
        guard cleaned.count == 56 else {
            throw ZKError.invalidRecoveryCode
        }
        var bits = 0
        var value = 0
        var bytes = Data()
        for ch in cleaned {
            guard let idx = base32Alphabet.firstIndex(of: ch) else {
                throw ZKError.invalidRecoveryCode
            }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((value >> bits) & 0xFF))
            }
        }
        guard bytes.count == 35 else {
            throw ZKError.invalidRecoveryCode
        }
        let rawKey = bytes.prefix(32)
        let checksum = bytes.suffix(3)
        let expectedMac = HMAC<SHA256>.authenticationCode(for: rawKey, using: SymmetricKey(data: recoveryDomain))
        guard Data(expectedMac).prefix(3) == checksum else {
            throw ZKError.invalidRecoveryCode
        }
        return SymmetricKey(data: rawKey)
    }

    // MARK: - Device Approval (P-256 ECDH + 6-Digit Match Code)

    public static func newDeviceKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    public static func matchCode(deviceID: String, publicKey: String) -> String {
        var input = Data(deviceDomain)
        input.append(Data(":\(deviceID):\(publicKey)".utf8))
        let digest = SHA256.hash(data: input)
        let bytes = Array(digest)
        let num = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) % 1_000_000
        let six = String(format: "%06d", num)
        return "\(six.prefix(3)) \(six.suffix(3))"
    }

    public static func grantForDevice(master: SymmetricKey, peerPublic: String, deviceID: String) throws -> String {
        guard let pubData = base64URLDecode(peerPublic) else {
            throw ZKError.invalidPublicKey
        }
        let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: pubData)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peerKey)
        var info = Data(deviceDomain)
        info.append(Data(":\(deviceID)".utf8))
        let wrapKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: 32
        )
        let masterData = master.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(masterData, using: wrapKey)
        guard let combined = sealed.combined else {
            throw ZKError.invalidCiphertext
        }
        var packet = Data()
        let ephPub = ephemeral.publicKey.x963Representation // 65 bytes
        packet.append(ephPub)
        packet.append(combined)
        return base64URLEncode(packet)
    }

    public static func openDeviceGrant(
        _ grant: String,
        privateKey: P256.KeyAgreement.PrivateKey,
        deviceID: String
    ) throws -> SymmetricKey {
        guard let packet = base64URLDecode(grant), packet.count > 65 else {
            throw ZKError.invalidCiphertext
        }
        let ephPubData = packet.prefix(65)
        let sealedData = packet.dropFirst(65)
        let ephPub = try P256.KeyAgreement.PublicKey(x963Representation: ephPubData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephPub)
        var info = Data(deviceDomain)
        info.append(Data(":\(deviceID)".utf8))
        let wrapKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: 32
        )
        let box = try AES.GCM.SealedBox(combined: sealedData)
        let masterData = try AES.GCM.open(box, using: wrapKey)
        return SymmetricKey(data: masterData)
    }

    // MARK: - Asymmetric File Request Sealing (sealForDrop / openDrop)

    public static func newDropKeyPair(keys: AccountKeys) throws -> (publicKey: String, wrappedPrivateKey: String) {
        let priv = P256.KeyAgreement.PrivateKey()
        let pubB64 = base64URLEncode(priv.publicKey.x963Representation)
        let sealedPriv = try AES.GCM.seal(priv.rawRepresentation, using: keys.wrap)
        guard let combined = sealedPriv.combined else {
            throw ZKError.invalidCiphertext
        }
        return (pubB64, base64URLEncode(combined))
    }

    public static func sealForDrop(secrets: FileSecrets, plainSize: UInt64, dropPublicKey: String) throws -> String {
        guard let pubData = base64URLDecode(dropPublicKey) else {
            throw ZKError.invalidPublicKey
        }
        let recipientPub = try P256.KeyAgreement.PublicKey(x963Representation: pubData)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPub)
        let symKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: dropDomain,
            outputByteCount: 32
        )
        var payload = secrets.key.withUnsafeBytes { Data($0) } // 32 bytes
        payload.append(secrets.nonce.prefix(8))                // 8 bytes
        var sizeBE = plainSize.bigEndian
        withUnsafeBytes(of: &sizeBE) { payload.append(contentsOf: $0) } // 8 bytes
        let sealed = try AES.GCM.seal(payload, using: symKey)
        guard let combined = sealed.combined else {
            throw ZKError.invalidCiphertext
        }
        var packet = Data(ephemeral.publicKey.x963Representation) // 65 bytes
        packet.append(combined)
        return base64URLEncode(packet)
    }

    public static func openDrop(
        sealed: String,
        wrappedPrivateKey: String,
        keys: AccountKeys
    ) throws -> (FileSecrets, UInt64) {
        guard let privWrapped = base64URLDecode(wrappedPrivateKey),
              let packet = base64URLDecode(sealed),
              packet.count > 65 else {
            throw ZKError.invalidCiphertext
        }
        let privBox = try AES.GCM.SealedBox(combined: privWrapped)
        let privRaw = try AES.GCM.open(privBox, using: keys.wrap)
        let privKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privRaw)

        let ephPub = try P256.KeyAgreement.PublicKey(x963Representation: packet.prefix(65))
        let shared = try privKey.sharedSecretFromKeyAgreement(with: ephPub)
        let symKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: dropDomain,
            outputByteCount: 32
        )
        let box = try AES.GCM.SealedBox(combined: packet.dropFirst(65))
        let opened = try AES.GCM.open(box, using: symKey)
        guard opened.count == 48 else {
            throw ZKError.invalidCiphertext
        }
        let keyData = opened.prefix(32)
        let nonceData = opened.subdata(in: 32..<40)
        let sizeData = opened.subdata(in: 40..<48)
        let plainSize = sizeData.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        return (FileSecrets(key: SymmetricKey(data: keyData), nonce: nonceData), plainSize)
    }

    // MARK: - Zero-Knowledge Share Links (makeShare / openShare)

    public static func makeShare(
        secrets: FileSecrets,
        fileName: String,
        accountKeys: AccountKeys
    ) throws -> (shareKeyB64: String, wrappedFileKey: String, fileNonce: String, encName: String, shareKeyWrap: String) {
        var skBytes = [UInt8](repeating: 0, count: shareKeyBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, skBytes.count, &skBytes)
        let skData = Data(skBytes)
        let derivedShareKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: skData),
            info: Data("helumi share v1".utf8),
            outputByteCount: 32
        )
        let rawFileKey = secrets.key.withUnsafeBytes { Data($0) }
        let sealedFileKey = try AES.GCM.seal(rawFileKey, using: derivedShareKey)
        let sealedName = try AES.GCM.seal(Data(fileName.utf8), using: derivedShareKey)
        let sealedSkForOwner = try AES.GCM.seal(skData, using: accountKeys.wrap)

        guard let fkCombined = sealedFileKey.combined,
              let nameCombined = sealedName.combined,
              let skCombined = sealedSkForOwner.combined else {
            throw ZKError.invalidCiphertext
        }
        return (
            shareKeyB64: base64URLEncode(skData),
            wrappedFileKey: base64URLEncode(fkCombined),
            fileNonce: base64URLEncode(secrets.nonce),
            encName: base64URLEncode(nameCombined),
            shareKeyWrap: base64URLEncode(skCombined)
        )
    }

    public static func openShare(
        shareKeyB64: String,
        wrappedFileKey: String,
        fileNonce: String,
        encName: String
    ) throws -> (FileSecrets, String) {
        guard let skData = base64URLDecode(shareKeyB64),
              let fkData = base64URLDecode(wrappedFileKey),
              let nonceData = base64URLDecode(fileNonce),
              let nameData = base64URLDecode(encName) else {
            throw ZKError.invalidCiphertext
        }
        let derivedShareKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: skData),
            info: Data("helumi share v1".utf8),
            outputByteCount: 32
        )
        let fkBox = try AES.GCM.SealedBox(combined: fkData)
        let rawFileKey = try AES.GCM.open(fkBox, using: derivedShareKey)
        let nameBox = try AES.GCM.SealedBox(combined: nameData)
        let plainNameData = try AES.GCM.open(nameBox, using: derivedShareKey)
        guard let fileName = String(data: plainNameData, encoding: .utf8) else {
            throw ZKError.invalidCiphertext
        }
        return (FileSecrets(key: SymmetricKey(data: rawFileKey), nonce: nonceData), fileName)
    }

    // MARK: - Base64URL Helpers

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = base64.count % 4
        if rem > 0 {
            base64.append(String(repeating: "=", count: 4 - rem))
        }
        return Data(base64Encoded: base64)
    }
}

