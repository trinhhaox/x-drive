# XDrive — Clean-Room Reconstruction of Helumi (`OrbitFS` + `OrbitCore.ZK` E2EE)

Ứng dụng ổ đĩa đám mây hiệu năng cao cho macOS, được tái tạo sạch (clean-room reconstruction) theo đúng kiến trúc đa tiến trình của **Helumi (`Orbit`)**.

## Kiến Trúc Đa Tiến Trình (4 Executables + `OrbitCore` + Cloudflare Worker)

1. **`OrbitCore` (`Sources/OrbitCore/`)**:
   - [`ZK.swift`](Sources/OrbitCore/ZK.swift): Hệ thống mật mã học Zero-Knowledge E2EE (`ZK.piece = 1,048,576` B, `ZK.tag = 16` B, `ZK.shareKeyBytes = 16` B, dẫn xuất khóa HKDF-SHA256 `AccountKeys(wrap, name, nameIndex)`, mã hóa tên tệp `e1:...` + chỉ mục mù `nameHash`, mã khôi phục Base32 kèm checksum HMAC, trao đổi khóa thiết bị P-256 ECDH kèm mã đối chiếu 6 số `matchCode`, và niêm phong bất đối xứng P-256 `sealForDrop`/`openDrop`).
   - [`DriveTree.swift`](Sources/OrbitCore/DriveTree.swift) & [`OrbitDrive.swift`](Sources/OrbitCore/OrbitDrive.swift): Cây inode ảo đa luồng, đồng bộ delta (`changes(since:)`), lưu snapshot tức thì (`tree-snapshot.json`) và `XattrStore`.
   - [`ChunkStore.swift`](Sources/OrbitCore/ChunkStore.swift) & [`ContentReader.swift`](Sources/OrbitCore/ContentReader.swift): Bộ nhớ đệm khối 1 MiB với cơ chế tự động thu hồi theo mức dung lượng trống ổ đĩa (`Limits`) nhưng bảo vệ tệp đã ghim `"Keep on This Mac"`, kết hợp đọc trước tuần tự (`prefetch`).
   - [`Staging.swift`](Sources/OrbitCore/Staging.swift) & [`LockedRemote.swift`](Sources/OrbitCore/LockedRemote.swift): Bộ đệm ghi cục bộ (Write-Back Caching), nguồn đọc luồng mã hóa theo từng khối 1 MiB (`LockedBlobSource`), bộ điều hợp E2EE trong suốt (`LockedRemote`) và tác nhân di trú dữ liệu nền (`PrivacySweep`).
   - [`PoliteUploads.swift`](Sources/OrbitCore/PoliteUploads.swift): Bộ điều tiết băng thông chống nghẽn mạng (`UploadGovernor` & `UploadPacer`) tự động đo RTT để giữ đường truyền mượt.
   - [`SearchIndex.swift`](Sources/OrbitCore/SearchIndex.swift): Công cụ tìm kiếm tức thì toàn cục trên `DriveTree`.

2. **`XDriveApp` (`Sources/XDriveApp/`)**:
   - Ứng dụng SwiftUI + `MenuBarExtra` quản lý ổ đĩa, tìm kiếm Spotlight, thiết lập khóa Zero-Knowledge E2EE, phê duyệt thiết bị mới và cấu hình bộ đệm.

3. **`OrbitMountHelper` (`Sources/OrbitMountHelper/`)**:
   - LaunchDaemon đặc quyền (`com.letcontactabhi.orbit.MountHelper`, giao thức phiên bản `6`) lắng nghe XPC để gắn kết `/Volumes/Helumi` với hệ thống tệp `OrbitFS`.

4. **`OrbitFS` (`Sources/OrbitFS/`)**:
   - Tiện ích mở rộng hệ thống tệp (`com.apple.fskit.fsmodule`) ánh xạ các thao tác POSIX/FSKit và kênh tín hiệu `._helumi-refresh` vào `OrbitDrive`.

5. **`OrbitFinder` (`Sources/OrbitFinder/`)**:
   - Tiện ích mở rộng `FIFinderSync` hiển thị huy hiệu đồng bộ (`uploading`, `synced`, `cloud`, `error`) và menu ngữ cảnh chuột phải trên Finder (`Copy Share Link`, `Keep on This Mac`, `Stop Sharing`, `Request Files...`).

6. **Cloudflare Workers Backend (`backend/`)**:
   - [`backend/src/index.ts`](backend/src/index.ts) & [`backend/schema.sql`](backend/schema.sql): Máy chủ REST API triển khai trên Cloudflare Workers + D1 SQLite + R2 Object Storage.

## Hướng dẫn Build & Kiểm thử

```bash
# Chạy toàn bộ Unit Tests (ZK Crypto, ChunkStore, DriveTree, E2EE OrbitDrive, PrivacySweep)
swift test

# Đóng gói gói ứng dụng hoàn chỉnh build/XDrive.app (gồm cả 4 thực thi & App Extensions)
chmod +x Scripts/build.sh
./Scripts/build.sh
```

