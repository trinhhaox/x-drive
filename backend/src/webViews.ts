// Web UI Portals for OAuth2 PKCE Sign-In, Zero-Knowledge #sk= Share Decryptor, and E2EE File Request Drop

export function renderOAuthDesktopHTML(
  code: string,
  redirectUri: string,
  email: string
): string {
  const callbackUrl = `${redirectUri}?code=${encodeURIComponent(code)}`;
  return `<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>XDrive — Xác thực OAuth2 PKCE</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0b0f19; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
    .card { background: #131b2e; border: 1px solid #26334d; border-radius: 16px; padding: 32px; max-width: 440px; width: 90%; text-align: center; box-shadow: 0 20px 50px rgba(0,0,0,0.45); }
    .btn { display: inline-block; background: #2563eb; color: #fff; text-decoration: none; font-weight: 600; padding: 12px 24px; border-radius: 10px; margin-top: 16px; }
    p { color: #94a3b8; font-size: 14px; line-height: 1.5; }
  </style>
</head>
<body>
  <div class="card">
    <h2>Đăng nhập XDrive Desktop</h2>
    <p>Tài khoản: <strong>${email}</strong> • Giao thức OAuth2 PKCE (S256)</p>
    <a class="btn" href="${callbackUrl}">Mở XDrive.app &amp; Hoàn tất Đăng nhập</a>
  </div>
  <script>
    setTimeout(() => { window.location.href = ${JSON.stringify(callbackUrl)}; }, 600);
  </script>
</body>
</html>`;
}

export function renderZeroKnowledgeShareHTML(token: string, share: any): string {
  const shareMetaJson = JSON.stringify({
    token: share.token,
    fileID: share.file_id,
    fileKey: share.file_key ?? null,
    fileNonce: share.file_nonce ?? null,
    encName: share.enc_name ?? null,
    plainName: share.plain_name ?? "SharedFile",
    size: share.size ?? 0,
    plainSize: share.plain_size ?? share.size ?? 0,
  });

  return `<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>XDrive — Chia sẻ Zero-Knowledge E2EE</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0b0f19; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
    .card { background: #131b2e; border: 1px solid #26334d; border-radius: 16px; padding: 32px; max-width: 520px; width: 92%; box-shadow: 0 20px 50px rgba(0,0,0,0.45); }
    .badge { display: inline-block; background: rgba(16,185,129,0.15); color: #34d399; padding: 4px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; margin-bottom: 12px; }
    h1 { font-size: 20px; margin: 0 0 8px; word-break: break-all; }
    p { color: #94a3b8; font-size: 14px; line-height: 1.5; }
    code { background: #0f172a; padding: 10px 12px; border-radius: 8px; display: block; margin: 12px 0; font-size: 12px; color: #38bdf8; word-break: break-all; }
    button { background: #10b981; color: #052e16; border: none; font-weight: 700; padding: 12px 20px; border-radius: 10px; cursor: pointer; font-size: 14px; width: 100%; margin-top: 8px; }
    button:disabled { opacity: 0.5; cursor: not-allowed; }
  </style>
</head>
<body>
  <div class="card">
    <span class="badge">Zero-Knowledge E2EE (#sk= Fragment • AES-256-GCM 1 MiB Pieces)</span>
    <h1 id="file-title">Đang giải mã siêu dữ liệu trong trình duyệt...</h1>
    <p id="file-meta">Khóa chia sẻ 128-bit nằm trong <code>window.location.hash</code> và không bao giờ được gửi tới máy chủ Cloudflare.</p>
    <code id="status-box">Share Token: ${token}</code>
    <button id="download-btn" disabled>Giải mã &amp; Tải xuống trong Trình duyệt</button>
  </div>
  <script>
    const SHARE = ${shareMetaJson};
    const PIECE_PLAIN = 1048576;
    const PIECE_TAG = 16;
    const PIECE_CIPHER = PIECE_PLAIN + PIECE_TAG;

    function b64UrlToBytes(b64url) {
      let s = b64url.replace(/-/g, "+").replace(/_/g, "/");
      while (s.length % 4 !== 0) s += "=";
      const bin = atob(s);
      const out = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    }

    async function hkdfDeriveKey(ikmBytes, infoStr) {
      const baseKey = await crypto.subtle.importKey("raw", ikmBytes, "HKDF", false, ["deriveKey"]);
      return crypto.subtle.deriveKey(
        { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode(infoStr) },
        baseKey,
        { name: "AES-GCM", length: 256 },
        false,
        ["decrypt"]
      );
    }

    async function aesGcmOpenCombined(combinedBytes, cryptoKey, aadBytes) {
      const iv = combinedBytes.slice(0, 12);
      const ctAndTag = combinedBytes.slice(12);
      const params = { name: "AES-GCM", iv, tagLength: 128 };
      if (aadBytes) params.additionalData = aadBytes;
      const plainBuf = await crypto.subtle.decrypt(params, cryptoKey, ctAndTag);
      return new Uint8Array(plainBuf);
    }

    function derivePieceNonce(baseNonce, index, isLast) {
      const n = new Uint8Array(baseNonce);
      let idx = BigInt(index);
      for (let i = 0; i < 8; i++) {
        n[11 - i] ^= Number((idx >> BigInt(i * 8)) & 0xffn);
      }
      if (isLast) n[0] ^= 0x80;
      return n;
    }

    let resolvedName = SHARE.plainName || "SharedFile";
    let unwrappedFileKey = null;
    let baseFileNonce = null;

    async function initSharePage() {
      const hash = window.location.hash.slice(1);
      const params = new URLSearchParams(hash);
      const sk = params.get("sk");
      const statusBox = document.getElementById("status-box");
      const titleEl = document.getElementById("file-title");
      const btn = document.getElementById("download-btn");

      if (!SHARE.fileKey) {
        titleEl.textContent = resolvedName;
        statusBox.textContent = "Tệp không mã hóa E2EE • Sẵn sàng tải xuống trực tiếp.";
        btn.disabled = false;
        btn.onclick = () => { window.location.href = "/s/" + SHARE.token + "/download"; };
        return;
      }

      if (!sk) {
        titleEl.textContent = "Thiếu khóa giải mã (#sk=...) trên URL";
        statusBox.textContent = "Vui lòng mở đầy đủ đường dẫn có chứa #sk=...";
        return;
      }

      try {
        const skBytes = b64UrlToBytes(sk);
        const wrapKey = await hkdfDeriveKey(skBytes, "helumi share v1");
        const nameKey = await hkdfDeriveKey(skBytes, "helumi share-name v1");

        if (SHARE.encName && SHARE.encName.startsWith("e1:")) {
          const nameCombined = b64UrlToBytes(SHARE.encName.slice(3));
          const nameBytes = await aesGcmOpenCombined(nameCombined, nameKey, new TextEncoder().encode("share"));
          resolvedName = new TextDecoder().decode(nameBytes);
        }

        const rawFileKey = await aesGcmOpenCombined(b64UrlToBytes(SHARE.fileKey), wrapKey, null);
        unwrappedFileKey = await crypto.subtle.importKey("raw", rawFileKey, { name: "AES-GCM" }, false, ["decrypt"]);
        baseFileNonce = b64UrlToBytes(SHARE.fileNonce);

        titleEl.textContent = resolvedName;
        statusBox.textContent = "Đã mở khóa E2EE thành công trong trình duyệt (" + SHARE.plainSize + " bytes).";
        btn.disabled = false;
        btn.onclick = downloadAndDecryptPieces;
      } catch (err) {
        titleEl.textContent = "Không thể mở khóa liên kết chia sẻ";
        statusBox.textContent = "Lỗi WebCrypto: " + (err && err.message ? err.message : String(err));
      }
    }

    async function downloadAndDecryptPieces() {
      const btn = document.getElementById("download-btn");
      const statusBox = document.getElementById("status-box");
      btn.disabled = true;
      statusBox.textContent = "Đang tải các khối mã hóa 1 MiB từ R2...";

      try {
        const res = await fetch("/s/" + SHARE.token + "/download");
        const cipherBuf = new Uint8Array(await res.arrayBuffer());
        const totalPieces = Math.max(1, Math.ceil(cipherBuf.length / PIECE_CIPHER));
        const plainChunks = [];

        for (let i = 0; i < totalPieces; i++) {
          const start = i * PIECE_CIPHER;
          const end = Math.min(cipherBuf.length, start + PIECE_CIPHER);
          const slice = cipherBuf.slice(start, end);
          const isLast = i === totalPieces - 1;
          const iv = derivePieceNonce(baseFileNonce, i, isLast);
          const plainPiece = await crypto.subtle.decrypt(
            { name: "AES-GCM", iv, tagLength: 128 },
            unwrappedFileKey,
            slice
          );
          plainChunks.push(new Uint8Array(plainPiece));
        }

        const blob = new Blob(plainChunks, { type: "application/octet-stream" });
        const a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = resolvedName;
        a.click();
        statusBox.textContent = "Đã giải mã " + totalPieces + " khối (1 MiB) và tải xuống hoàn tất!";
      } catch (err) {
        statusBox.textContent = "Lỗi giải mã khối: " + (err && err.message ? err.message : String(err));
      } finally {
        btn.disabled = false;
      }
    }

    initSharePage();
  </script>
</body>
</html>`;
}

export function renderFileRequestDropHTML(token: string, reqInfo: any): string {
  const metaJson = JSON.stringify({
    token,
    folderName: reqInfo.folder_name ?? "RequestFolder",
    dropPublic: reqInfo.drop_public ?? null,
  });

  return `<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>XDrive — Gửi tệp vào ${reqInfo.folder_name ?? "Thư mục"}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0b0f19; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
    .card { background: #131b2e; border: 1px solid #26334d; border-radius: 16px; padding: 32px; max-width: 500px; width: 92%; box-shadow: 0 20px 50px rgba(0,0,0,0.45); }
    .badge { display: inline-block; background: rgba(59,130,246,0.18); color: #60a5fa; padding: 4px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; margin-bottom: 12px; }
    .dropzone { border: 2px dashed #3b82f6; border-radius: 12px; padding: 28px; text-align: center; margin: 16px 0; cursor: pointer; }
    code { background: #0f172a; padding: 8px 12px; border-radius: 8px; display: block; font-size: 12px; color: #38bdf8; }
  </style>
</head>
<body>
  <div class="card">
    <span class="badge">Hộp nhận tệp Bất đối xứng (P-256 ECDH sealForDrop)</span>
    <h2>Gửi tệp vào: ${reqInfo.folder_name ?? "Thư mục"}</h2>
    <div class="dropzone" onclick="document.getElementById('file-input').click()">
      <p>Nhấn để chọn tệp tải lên an toàn</p>
      <input id="file-input" type="file" style="display:none" onchange="uploadSelectedFile(this.files[0])" />
    </div>
    <code id="drop-status">Sẵn sàng nhận tệp (${reqInfo.drop_public ? "Đã bật khóa công khai P-256 ECDH" : "Chế độ tiêu chuẩn"})</code>
  </div>
  <script>
    const REQ = ${metaJson};
    async function uploadSelectedFile(file) {
      if (!file) return;
      const statusEl = document.getElementById("drop-status");
      statusEl.textContent = "Đang tải tệp '" + file.name + "' lên XDrive...";
      const buf = await file.arrayBuffer();
      const res = await fetch("/r/" + REQ.token + "/upload?name=" + encodeURIComponent(file.name), {
        method: "POST",
        body: buf
      });
      if (res.ok) {
        statusEl.textContent = "Đã gửi tệp '" + file.name + "' thành công!";
      } else {
        statusEl.textContent = "Gửi tệp thất bại (HTTP " + res.status + ").";
      }
    }
  </script>
</body>
</html>`;
}

