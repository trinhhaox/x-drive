import XCTest
import CryptoKit
@testable import OrbitCore

final class OrbitCoreTests: XCTestCase {

    // MARK: - 1. Zero-Knowledge E2EE Cryptography (OrbitCore.ZK) Tests

    func testZKConstantsMatchHelumiBinary() {
        XCTAssertEqual(ZK.piece, 1_048_576, "ZK.piece must be exactly 1 MiB")
        XCTAssertEqual(ZK.tag, 16, "ZK.tag must be 16 bytes (128-bit GCM tag)")
        XCTAssertEqual(ZK.shareKeyBytes, 16, "ZK.shareKeyBytes must be 16 bytes")
        XCTAssertEqual(ChunkStore.defaultChunkSize, 1_048_576, "ChunkStore.defaultChunkSize must be 1 MiB")
        XCTAssertEqual(MountHelper.version, 6)
        XCTAssertEqual(MountHelper.mountPoint, "/Volumes/Helumi")
        XCTAssertEqual(MountHelper.fileSystemType, "OrbitFS")
    }

    func testZKKeyDerivationAndKeyCheck() throws {
        let master = ZK.newMasterKey()
        let keys = ZK.deriveKeys(from: master)
        let check = try ZK.makeKeyCheck(keys)
        XCTAssertTrue(ZK.verifyKeyCheck(check, keys: keys))

        let wrongKeys = ZK.deriveKeys(from: ZK.newMasterKey())
        XCTAssertFalse(ZK.verifyKeyCheck(check, keys: wrongKeys))
    }

    func testZKNameEncryptionAndBlindIndex() throws {
        let keys = ZK.deriveKeys(from: ZK.newMasterKey())
        let wire1 = try ZK.lockName("Báo cáo Tài chính Q4.xlsx", parentID: "dir_123", keys: keys)
        let wire2 = try ZK.lockName("Báo cáo Tài chính Q4.xlsx", parentID: "dir_123", keys: keys)

        XCTAssertTrue(wire1.encName.hasPrefix("e1:"))
        XCTAssertNotEqual(wire1.encName, wire2.encName, "Random GCM nonce must produce distinct ciphertexts")
        XCTAssertEqual(wire1.nameHash, wire2.nameHash, "Blind index nameHash must be deterministic per parentID + normalized name")

        let unlocked = try ZK.unlockName(wire1.encName, keys: keys)
        XCTAssertEqual(unlocked, "Báo cáo Tài chính Q4.xlsx")
    }

    func testZKPieceEncryptionAndRandomAccessRangeMath() throws {
        let plainSize: UInt64 = UInt64(ZK.piece * 2 + 12_345) // 2 full pieces + 1 partial piece = 3 pieces
        XCTAssertEqual(ZK.pieceCount(plainSize: plainSize), 3)
        XCTAssertEqual(ZK.cipherSize(plainSize: plainSize), plainSize + UInt64(3 * ZK.tag))

        // Range spanning end of piece 0 into middle of piece 1
        let offset = UInt64(ZK.piece - 100)
        let length = 500
        let rangePlan = ZK.plainRange(offset: offset, length: length, plainSize: plainSize)
        XCTAssertEqual(rangePlan.firstPiece, 0)
        XCTAssertEqual(rangePlan.lastPiece, 1)
        XCTAssertEqual(rangePlan.cipherOffset, 0)
        XCTAssertEqual(rangePlan.cipherLength, (ZK.piece + ZK.tag) * 2)

        // Verify lockPiece / unlockPiece and AAD tamper protection
        let secrets = ZK.newFileSecrets()
        let sample = Data("Hello Zero-Knowledge Piece".utf8)
        let cipher = try ZK.lockPiece(sample, index: 0, last: false, secrets: secrets)
        XCTAssertEqual(cipher.count, sample.count + ZK.tag)

        let opened = try ZK.unlockPiece(cipher, index: 0, last: false, secrets: secrets)
        XCTAssertEqual(opened, sample)

        // Swapping piece index or `last` flag must fail GCM AAD authentication
        XCTAssertThrowsError(try ZK.unlockPiece(cipher, index: 1, last: false, secrets: secrets))
        XCTAssertThrowsError(try ZK.unlockPiece(cipher, index: 0, last: true, secrets: secrets))
    }

    func testZKRecoveryCodeRoundTripAndChecksum() throws {
        let master = ZK.newMasterKey()
        let code = ZK.packRecovery(master)
        XCTAssertEqual(code.split(separator: "-").count, 7)

        let unpacked = try ZK.unpackRecovery(code)
        XCTAssertEqual(ZK.deriveKeys(from: master), ZK.deriveKeys(from: unpacked))

        // Corrupting a character must trigger invalidRecoveryCode
        var corrupted = code
        corrupted.removeLast()
        corrupted.append(code.last == "A" ? "B" : "A")
        XCTAssertThrowsError(try ZK.unpackRecovery(corrupted))
    }

    func testZKDeviceApprovalECDHAndMatchCode() throws {
        let master = ZK.newMasterKey()
        let newDevicePriv = ZK.newDeviceKeyPair()
        let peerPubB64 = ZK.base64URLEncode(newDevicePriv.publicKey.x963Representation)
        let deviceID = "req_998877"

        let code1 = ZK.matchCode(deviceID: deviceID, publicKey: peerPubB64)
        let code2 = ZK.matchCode(deviceID: deviceID, publicKey: peerPubB64)
        XCTAssertEqual(code1, code2)
        XCTAssertEqual(code1.count, 7) // "XXX XXX"

        let grant = try ZK.grantForDevice(master: master, peerPublic: peerPubB64, deviceID: deviceID)
        let openedMaster = try ZK.openDeviceGrant(grant, privateKey: newDevicePriv, deviceID: deviceID)
        XCTAssertEqual(ZK.deriveKeys(from: master), ZK.deriveKeys(from: openedMaster))
    }

    func testZKAsymmetricDropAndShareLinks() throws {
        let master = ZK.newMasterKey()
        let keys = ZK.deriveKeys(from: master)
        let dropPair = try ZK.newDropKeyPair(keys: keys)

        let fileSecrets = ZK.newFileSecrets()
        let plainSize: UInt64 = 98_765
        let sealedDrop = try ZK.sealForDrop(secrets: fileSecrets, plainSize: plainSize, dropPublicKey: dropPair.publicKey)
        let (openedSecrets, openedSize) = try ZK.openDrop(
            sealed: sealedDrop,
            wrappedPrivateKey: dropPair.wrappedPrivateKey,
            keys: keys
        )
        XCTAssertEqual(openedSecrets, fileSecrets)
        XCTAssertEqual(openedSize, plainSize)

        let share = try ZK.makeShare(secrets: fileSecrets, fileName: "SecretContract.pdf", accountKeys: keys)
        let (sharedSecrets, sharedName) = try ZK.openShare(
            shareKeyB64: share.shareKeyB64,
            wrappedFileKey: share.wrappedFileKey,
            fileNonce: share.fileNonce,
            encName: share.encName
        )
        XCTAssertEqual(sharedSecrets, fileSecrets)
        XCTAssertEqual(sharedName, "SecretContract.pdf")
    }

    // MARK: - 2. DriveTree, ChunkStore & End-to-End Encrypted OrbitDrive Tests

    func testChunkStoreEvictionRespectsPinnedFiles() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("chunktest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let limits = ChunkStore.Limits(
            maxBytes: 2_500,
            minFreeBytes: 1_000,
            streamingBytes: 2_500,
            criticalFreeBytes: 500,
            lastResortBytes: 1_000,
            outOfSpaceFreeBytes: 100
        )
        let store = ChunkStore(
            baseDirectory: tempDir,
            chunkSize: 1_000,
            limits: limits,
            freeSpaceProvider: { 10_000_000 }
        )
        store.setPinnedRemoteIDs(["pinned_file"])

        store.put(ChunkKey(remoteID: "pinned_file", version: 1, index: 0), data: Data(repeating: 1, count: 1_000))
        store.put(ChunkKey(remoteID: "unpinned_old", version: 1, index: 0), data: Data(repeating: 2, count: 1_000))
        store.put(ChunkKey(remoteID: "unpinned_new", version: 1, index: 0), data: Data(repeating: 3, count: 1_000))

        // Total would be 3,000 > 2,500 ceiling -> "unpinned_old" must be evicted while "pinned_file" remains intact
        XCTAssertNotNil(store.get(ChunkKey(remoteID: "pinned_file", version: 1, index: 0)))
        XCTAssertNil(store.get(ChunkKey(remoteID: "unpinned_old", version: 1, index: 0)))
        XCTAssertNotNil(store.get(ChunkKey(remoteID: "unpinned_new", version: 1, index: 0)))
    }

    func testEndToEndEncryptedDriveAndPrivacySweep() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("drivetest_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        SharedContainer.overrideDirectory = tempDir
        defer { SharedContainer.overrideDirectory = nil }

        let backend = LocalWireRemote()
        let keyManager = KeyManager(localStore: InMemorySecretStore(), cloudStore: InMemorySecretStore())
        let lockedRemote = LockedRemote(inner: backend, keyManager: keyManager)
        let drive = OrbitDrive(baseDirectory: tempDir, remote: lockedRemote)

        // 1. Create an unsealed file while E2EE is off
        let node1 = try await drive.createItem(name: "PlainReport.txt", parentID: DriveTree.rootID, kind: .file)
        let content1 = Data("Unsealed initial content before E2EE is enabled.".utf8)
        _ = try await drive.writeFile(nodeID: node1.id, data: content1, offset: 0)
        await drive.closeFile(nodeID: node1.id)

        let unsealedBefore = try await backend.unsealedFiles()
        XCTAssertEqual(unsealedBefore.count, 1)

        // 2. Enable Zero-Knowledge E2EE and run PrivacySweep migration
        _ = try keyManager.setupNewMasterKey(for: "user_1")
        let sweep = PrivacySweep(remote: backend, keyManager: keyManager)
        let progress = try await sweep.runSweep()
        XCTAssertEqual(progress.total, 1)
        XCTAssertEqual(progress.done, 1)

        let unsealedAfter = try await backend.unsealedFiles()
        XCTAssertEqual(unsealedAfter.count, 0, "All files on backend must now have encrypted WireName and WireSecrets")

        // 3. Create a large multi-piece file (1.4 MiB > 1 MiB ZK.piece) with E2EE active
        let node2 = try await drive.createItem(name: "EncryptedMultiPiece.bin", parentID: DriveTree.rootID, kind: .file)
        var largePlain = Data(count: ZK.piece + 400_000)
        for i in stride(from: 0, to: largePlain.count, by: 4096) {
            largePlain[i] = UInt8((i / 4096) & 0xFF)
        }
        _ = try await drive.writeFile(nodeID: node2.id, data: largePlain, offset: 0)
        await drive.closeFile(nodeID: node2.id)

        // Clear local cache to force decryption fetch from backend across piece 0 and piece 1 boundary
        drive.chunkStore.clearAll(includePinned: true)
        let crossPieceOffset = UInt64(ZK.piece - 2048)
        let crossPieceLength = 8192
        let readBack = try await drive.readFile(nodeID: node2.id, offset: crossPieceOffset, length: crossPieceLength)
        let expectedSlice = largePlain.subdata(in: Int(crossPieceOffset)..<(Int(crossPieceOffset) + crossPieceLength))
        XCTAssertEqual(readBack, expectedSlice)

        // 4. Verify Spotlight SearchIndex finds both files
        let index = SearchIndex()
        index.rebuild(from: drive.tree)
        let hits = index.search(query: "multipiece")
        XCTAssertEqual(hits.first?.name, "EncryptedMultiPiece.bin")
    }

    func testShareMakerFragmentURLAndUploadGovernorThrottling() throws {
        let master = ZK.newMasterKey()
        let keys = ZK.deriveKeys(from: master)
        let secrets = ZK.newFileSecrets()
        let baseShare = URL(string: "https://www.helumi.app/s/abc123xyz")!

        let pkg = try ShareMaker.makeEncryptedShareURL(
            baseShareURL: baseShare,
            secrets: secrets,
            fileName: "BoardPresentation.key",
            accountKeys: keys
        )
        XCTAssertTrue(pkg.fullShareURL.absoluteString.contains("#sk="))

        let fragment = URLComponents(url: pkg.fullShareURL, resolvingAgainstBaseURL: false)?.fragment ?? ""
        let skB64 = String(fragment.dropFirst(3))
        let (openedSecrets, openedName) = try ZK.openShare(
            shareKeyB64: skB64,
            wrappedFileKey: pkg.wrappedFileKey,
            fileNonce: pkg.fileNonce,
            encName: pkg.encName
        )
        XCTAssertEqual(openedSecrets, secrets)
        XCTAssertEqual(openedName, "BoardPresentation.key")

        // Verify UploadGovernor detects bufferbloat (high RTT spike) and enables throttling
        let gov = UploadGovernor(enabled: true)
        gov.recordRTT(milliseconds: 20.0)
        XCTAssertFalse(gov.isThrottling)
        // Simulate loaded RTT spike (+150ms bloat)
        gov.recordRTT(milliseconds: 220.0)
        gov.recordRTT(milliseconds: 240.0)
        XCTAssertTrue(gov.isThrottling, "UploadGovernor must throttle when RTT spikes above baseline")
    }

    func testErrorReporterAndXattrStoreRoundTrip() throws {
        ErrorReporter.shared.clearQueue()
        ErrorReporter.shared.report(component: "OrbitFS", message: "Simulated FSKit mount diagnostic")
        let reports = ErrorReporter.shared.latestReports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.component, "OrbitFS")

        let xattrs = XattrStore()
        let sampleTag = Data("com.apple.FinderInfo.Tag".utf8)
        xattrs.set(nodeID: 42, name: "com.apple.FinderInfo", value: sampleTag)
        XCTAssertEqual(xattrs.get(nodeID: 42, name: "com.apple.FinderInfo"), sampleTag)
        XCTAssertEqual(xattrs.list(nodeID: 42), ["com.apple.FinderInfo"])
        xattrs.set(nodeID: 42, name: "com.apple.FinderInfo", value: nil)
        XCTAssertNil(xattrs.get(nodeID: 42, name: "com.apple.FinderInfo"))
    }

    func testGitHubReleaseVersionComparisonAndSHA256Verification() throws {
        XCTAssertTrue(GitHubUpdateVerifier.isVersion("v0.3.14", newerThan: "0.3.13"))
        XCTAssertTrue(GitHubUpdateVerifier.isVersion("0.4.0", newerThan: "v0.3.99"))
        XCTAssertTrue(GitHubUpdateVerifier.isVersion("1.0.0", newerThan: "0.9.9"))
        XCTAssertFalse(GitHubUpdateVerifier.isVersion("v0.3.13", newerThan: "0.3.13"))
        XCTAssertFalse(GitHubUpdateVerifier.isVersion("0.3.12", newerThan: "0.3.13"))

        let sampleReleaseJSON = """
        {
          "tag_name": "v0.3.14",
          "name": "XDrive v0.3.14",
          "body": "### Release Notes\\n- Faster FSKit streaming",
          "html_url": "https://github.com/trinhhaox/x-drive/releases/tag/v0.3.14",
          "prerelease": false,
          "draft": false,
          "assets": [
            {
              "name": "XDrive-0.3.14.dmg",
              "browser_download_url": "https://github.com/trinhhaox/x-drive/releases/download/v0.3.14/XDrive-0.3.14.dmg",
              "size": 1400000
            },
            {
              "name": "XDrive-0.3.14-macos-arm64.zip",
              "browser_download_url": "https://github.com/trinhhaox/x-drive/releases/download/v0.3.14/XDrive-0.3.14-macos-arm64.zip",
              "size": 1200000
            },
            {
              "name": "SHA256SUMS.txt",
              "browser_download_url": "https://github.com/trinhhaox/x-drive/releases/download/v0.3.14/SHA256SUMS.txt",
              "size": 192
            }
          ]
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(GitHubReleaseInfo.self, from: sampleReleaseJSON)
        XCTAssertEqual(info.cleanVersion, "0.3.14")
        XCTAssertEqual(info.preferredAppArchiveAsset?.name, "XDrive-0.3.14-macos-arm64.zip")
        XCTAssertEqual(info.sha256SumsAsset?.name, "SHA256SUMS.txt")

        let payload = Data("fake-zip-archive-bytes".utf8)
        let expectedHex = GitHubUpdateVerifier.sha256Hex(of: payload)
        let sumsContent = """
        \(expectedHex)  XDrive-0.3.14-macos-arm64.zip
        bb8e7b2ff1cf3126307f2cc18b57ac9690ed04e196aeb8e941e1ae11cb5244ae  XDrive-0.3.14.dmg
        """
        XCTAssertEqual(
            GitHubUpdateVerifier.expectedSHA256(for: "XDrive-0.3.14-macos-arm64.zip", in: sumsContent),
            expectedHex
        )
    }
}

