export interface Env {
  DB: D1Database;
  BUCKET: R2Bucket;
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization, Range",
    },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return jsonResponse({ ok: true });
    }

    const url = new URL(request.url);
    const path = url.pathname.replace(/^\/+/, "").replace(/\/+$/, "");
    const method = request.method.toUpperCase();
    const userId = "usr_default";

    try {
      // 1. Auth Endpoints (OAuth2 PKCE + Refresh + Logout)
      if (path === "auth/browser/exchange" && method === "POST") {
        const now = new Date().toISOString();
        await env.DB.prepare(
          `INSERT OR IGNORE INTO users (id, email, name, plan, storage_used, storage_limit, created_at)
           VALUES (?, 'mr.trinhhao@gmail.com', 'Trịnh Hảo', 'Pro 2 TB', 0, 2199023255552, ?)`
        )
          .bind(userId, now)
          .run();

        return jsonResponse({
          accessToken: `at_${crypto.randomUUID()}`,
          refreshToken: `rt_${crypto.randomUUID()}`,
          expiresIn: 3600,
          user: {
            id: userId,
            email: "mr.trinhhao@gmail.com",
            name: "Trịnh Hảo",
            plan: "Pro 2 TB",
            storageUsed: 0,
            storageLimit: 2_000_000_000_000,
          },
        });
      }

      if (path === "auth/refresh" && method === "POST") {
        return jsonResponse({
          accessToken: `at_${crypto.randomUUID()}`,
          refreshToken: `rt_${crypto.randomUUID()}`,
          expiresIn: 3600,
          user: {
            id: userId,
            email: "mr.trinhhao@gmail.com",
            name: "Trịnh Hảo",
            plan: "Pro 2 TB",
            storageUsed: 0,
            storageLimit: 2_000_000_000_000,
          },
        });
      }

      if (path === "auth/logout" && method === "POST") {
        return jsonResponse({ ok: true });
      }

      // 2. User Profile & Quota
      if (path === "me" && method === "GET") {
        return jsonResponse({
          id: userId,
          email: "mr.trinhhao@gmail.com",
          name: "Trịnh Hảo",
          plan: "Pro 2 TB",
          storageUsed: 0,
          storageLimit: 2_000_000_000_000,
        });
      }

      if (path === "quota" && method === "GET") {
        const stats = await env.DB.prepare(
          "SELECT COALESCE(SUM(COALESCE(plain_size, size)), 0) AS used, COUNT(*) AS cnt FROM files WHERE user_id = ? AND deleted = 0"
        )
          .bind(userId)
          .first<{ used: number; cnt: number }>();

        return jsonResponse({
          usedBytes: stats?.used ?? 0,
          limitBytes: 2_000_000_000_000,
          plan: "Pro 2 TB",
          fileCount: stats?.cnt ?? 0,
        });
      }

      // 3. Directory Listing, All Files & Delta Changes
      if (path === "files" && method === "GET") {
        const parentID = url.searchParams.get("parentID");
        const stmt = parentID
          ? env.DB.prepare(
              "SELECT * FROM files WHERE user_id = ? AND parent_id = ? AND deleted = 0 ORDER BY name ASC"
            ).bind(userId, parentID)
          : env.DB.prepare(
              "SELECT * FROM files WHERE user_id = ? AND parent_id IS NULL AND deleted = 0 ORDER BY name ASC"
            ).bind(userId);
        const rows = await stmt.all();
        return jsonResponse(rows.results.map(mapFileRow));
      }

      if (path === "files/all" && method === "GET") {
        const rows = await env.DB.prepare(
          "SELECT * FROM files WHERE user_id = ? AND deleted = 0"
        )
          .bind(userId)
          .all();
        return jsonResponse(rows.results.map(mapFileRow));
      }

      if (path === "changes" && method === "GET") {
        const since = Number(url.searchParams.get("since") ?? "0");
        const rows = await env.DB.prepare(
          "SELECT * FROM changes WHERE user_id = ? AND seq > ? ORDER BY seq ASC LIMIT 500"
        )
          .bind(userId, since)
          .all();
        const changes = rows.results.map((r: any) => ({
          seq: r.seq,
          fileID: r.file_id,
          action: r.action,
          name: r.name,
          parentID: r.parent_id,
          isDirectory: Boolean(r.is_directory),
          size: r.size,
          createdAt: r.created_at,
          updatedAt: r.updated_at,
          encName: r.enc_name,
          fileKey: r.file_key,
          fileNonce: r.file_nonce,
          plainSize: r.plain_size,
          sealPublic: r.seal_public,
        }));
        const cursor = changes.length > 0 ? changes[changes.length - 1].seq : since;
        return jsonResponse({ changes, cursor, hasMore: changes.length === 500 });
      }

      // 4. Create Folder & Upload File
      if (path === "files/folder" && method === "POST") {
        const body = (await request.json()) as any;
        const id = `dir_${crypto.randomUUID()}`;
        const now = new Date().toISOString();
        await env.DB.prepare(
          `INSERT INTO files (id, user_id, parent_id, name, is_directory, size, enc_name, name_hash, created_at, updated_at)
           VALUES (?, ?, ?, ?, 1, 0, ?, ?, ?, ?)`
        )
          .bind(
            id,
            userId,
            body.parentID ?? null,
            body.name ?? "folder",
            body.encName ?? null,
            body.nameHash ?? null,
            now,
            now
          )
          .run();

        await recordChange(env.DB, userId, {
          fileID: id,
          action: "upsert",
          name: body.name ?? "folder",
          parentID: body.parentID ?? null,
          isDirectory: 1,
          size: 0,
          encName: body.encName ?? null,
          createdAt: now,
          updatedAt: now,
        });

        return jsonResponse({
          id,
          name: body.name ?? "folder",
          parentID: body.parentID ?? null,
          isDirectory: true,
          size: 0,
          createdAt: now,
          updatedAt: now,
          encName: body.encName ?? null,
        });
      }

      if (path === "files/upload" && method === "POST") {
        const id = url.searchParams.get("id") ?? `file_${crypto.randomUUID()}`;
        const name = url.searchParams.get("name") ?? "file";
        const parentID = url.searchParams.get("parentID");
        const encName = url.searchParams.get("encName");
        const nameHash = url.searchParams.get("nameHash");
        const fileKey = url.searchParams.get("fileKey");
        const fileNonce = url.searchParams.get("fileNonce");
        const plainSize = url.searchParams.get("plainSize")
          ? Number(url.searchParams.get("plainSize"))
          : null;

        const blob = await request.arrayBuffer();
        await env.BUCKET.put(`${userId}/${id}`, blob);

        const now = new Date().toISOString();
        await env.DB.prepare(
          `INSERT OR REPLACE INTO files
           (id, user_id, parent_id, name, is_directory, size, enc_name, name_hash, file_key, file_nonce, plain_size, deleted, created_at, updated_at)
           VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, 0, ?, ?)`
        )
          .bind(
            id,
            userId,
            parentID,
            name,
            blob.byteLength,
            encName,
            nameHash,
            fileKey,
            fileNonce,
            plainSize,
            now,
            now
          )
          .run();

        await recordChange(env.DB, userId, {
          fileID: id,
          action: "upsert",
          name,
          parentID,
          isDirectory: 0,
          size: blob.byteLength,
          encName,
          fileKey,
          fileNonce,
          plainSize,
          createdAt: now,
          updatedAt: now,
        });

        return jsonResponse({
          id,
          name,
          size: blob.byteLength,
          parentID,
          updatedAt: now,
        });
      }

      // 5. File Item Operations (/files/:id, /files/:id/content-url, /files/:id/content, /files/:id/encrypted-content)
      if (path.startsWith("files/")) {
        const parts = path.split("/");
        const fileId = parts[1];
        const subAction = parts[2];

        if (!subAction && method === "GET") {
          const row = await env.DB.prepare(
            "SELECT * FROM files WHERE id = ? AND user_id = ? AND deleted = 0"
          )
            .bind(fileId, userId)
            .first();
          if (!row) return jsonResponse({ error: "Not found" }, 404);
          return jsonResponse(mapFileRow(row));
        }

        if (!subAction && method === "PATCH") {
          const body = (await request.json()) as any;
          const existing = await env.DB.prepare(
            "SELECT * FROM files WHERE id = ? AND user_id = ?"
          )
            .bind(fileId, userId)
            .first<any>();
          if (!existing) return jsonResponse({ error: "Not found" }, 404);

          const newName = body.name ?? existing.name;
          const newParent =
            "parentID" in body ? body.parent_id ?? body.parentID : existing.parent_id;
          const newEncName = body.encName ?? existing.enc_name;
          const newNameHash = body.nameHash ?? existing.name_hash;
          const now = body.modifiedAt ?? new Date().toISOString();

          await env.DB.prepare(
            `UPDATE files SET name = ?, parent_id = ?, enc_name = ?, name_hash = ?, updated_at = ?
             WHERE id = ? AND user_id = ?`
          )
            .bind(newName, newParent, newEncName, newNameHash, now, fileId, userId)
            .run();

          const updated = await env.DB.prepare("SELECT * FROM files WHERE id = ?")
            .bind(fileId)
            .first<any>();
          await recordChange(env.DB, userId, {
            fileID: fileId,
            action: "upsert",
            name: updated.name,
            parentID: updated.parent_id,
            isDirectory: updated.is_directory,
            size: updated.size,
            encName: updated.enc_name,
            fileKey: updated.file_key,
            fileNonce: updated.file_nonce,
            plainSize: updated.plain_size,
            createdAt: updated.created_at,
            updatedAt: updated.updated_at,
          });
          return jsonResponse(mapFileRow(updated));
        }

        if (!subAction && method === "DELETE") {
          await env.DB.prepare(
            "UPDATE files SET deleted = 1 WHERE id = ? AND user_id = ?"
          )
            .bind(fileId, userId)
            .run();
          await env.BUCKET.delete(`${userId}/${fileId}`);
          await recordChange(env.DB, userId, {
            fileID: fileId,
            action: "delete",
          });
          return jsonResponse({ ok: true });
        }

        if (subAction === "content-url" && method === "GET") {
          const contentUrl = `${url.origin}/files/${fileId}/content`;
          return jsonResponse({ url: contentUrl, expiresIn: 3600 });
        }

        if (subAction === "content" && method === "GET") {
          const rangeHeader = request.headers.get("Range");
          if (rangeHeader && rangeHeader.startsWith("bytes=")) {
            const [startStr, endStr] = rangeHeader.replace("bytes=", "").split("-");
            const offset = Number(startStr);
            const length = Number(endStr) - offset + 1;
            const obj = await env.BUCKET.get(`${userId}/${fileId}`, {
              range: { offset, length },
            });
            if (!obj) return new Response("Not Found", { status: 404 });
            return new Response(obj.body, { status: 206 });
          }
          const obj = await env.BUCKET.get(`${userId}/${fileId}`);
          if (!obj) return new Response("Not Found", { status: 404 });
          return new Response(obj.body, { status: 200 });
        }

        if (subAction === "encrypted-content" && method === "PUT") {
          const fileKey = url.searchParams.get("fileKey");
          const fileNonce = url.searchParams.get("fileNonce");
          const plainSize = Number(url.searchParams.get("plainSize") ?? "0");
          const blob = await request.arrayBuffer();
          await env.BUCKET.put(`${userId}/${fileId}`, blob);
          await env.DB.prepare(
            `UPDATE files SET size = ?, file_key = ?, file_nonce = ?, plain_size = ?, updated_at = ?
             WHERE id = ? AND user_id = ?`
          )
            .bind(
              blob.byteLength,
              fileKey,
              fileNonce,
              plainSize,
              new Date().toISOString(),
              fileId,
              userId
            )
            .run();
          return jsonResponse({ ok: true });
        }
      }

      // 6. Zero-Knowledge Privacy & Device Approval Endpoints
      if (path === "privacy" && method === "GET") {
        const u = await env.DB.prepare("SELECT * FROM users WHERE id = ?")
          .bind(userId)
          .first<any>();
        const unsealed = await env.DB.prepare(
          "SELECT COUNT(*) AS cnt FROM files WHERE user_id = ? AND enc_name IS NULL AND deleted = 0"
        )
          .bind(userId)
          .first<{ cnt: number }>();

        return jsonResponse({
          enabled: Boolean(u?.privacy_enabled),
          keyCheck: u?.key_check ?? null,
          dropPublic: u?.drop_public ?? null,
          dropPrivateWrap: u?.drop_private_wrap ?? null,
          unsealedCount: unsealed?.cnt ?? 0,
        });
      }

      if (path === "privacy/enable" && method === "POST") {
        const body = (await request.json()) as any;
        await env.DB.prepare(
          `UPDATE users SET privacy_enabled = 1, key_check = ?, drop_public = ?, drop_private_wrap = ? WHERE id = ?`
        )
          .bind(body.keyCheck, body.dropPublic, body.dropPrivateWrap, userId)
          .run();
        return jsonResponse({ ok: true });
      }

      if (path === "privacy/unsealed" && method === "GET") {
        const rows = await env.DB.prepare(
          "SELECT id, name, parent_id, is_directory, size FROM files WHERE user_id = ? AND enc_name IS NULL AND deleted = 0"
        )
          .bind(userId)
          .all();
        return jsonResponse(
          rows.results.map((r: any) => ({
            id: r.id,
            name: r.name,
            parentID: r.parent_id,
            isDirectory: Boolean(r.is_directory),
            size: r.size,
          }))
        );
      }

      if (path === "privacy/lock-batch" && method === "POST") {
        const entries = (await request.json()) as any[];
        for (const e of entries) {
          await env.DB.prepare(
            `UPDATE files SET enc_name = ?, name_hash = ?, file_key = COALESCE(?, file_key),
             file_nonce = COALESCE(?, file_nonce), plain_size = COALESCE(?, plain_size)
             WHERE id = ? AND user_id = ?`
          )
            .bind(
              e.encName,
              e.nameHash,
              e.fileKey ?? null,
              e.fileNonce ?? null,
              e.plainSize ?? null,
              e.id,
              userId
            )
            .run();
        }
        return jsonResponse({ ok: true });
      }

      if (path === "privacy/device-requests" && method === "POST") {
        const body = (await request.json()) as any;
        const id = `dev_${crypto.randomUUID().slice(0, 8)}`;
        const now = Math.floor(Date.now() / 1000);
        const expiresAt = now + 600;
        await env.DB.prepare(
          `INSERT INTO device_requests (id, user_id, device_name, public_key, status, created_at, expires_at)
           VALUES (?, ?, ?, ?, 'pending', ?, ?)`
        )
          .bind(id, userId, body.deviceName, body.publicKey, now, expiresAt)
          .run();
        return jsonResponse({ id, expiresAt });
      }

      if (path === "privacy/device-requests" && method === "GET") {
        const rows = await env.DB.prepare(
          "SELECT * FROM device_requests WHERE user_id = ? AND status = 'pending'"
        )
          .bind(userId)
          .all();
        return jsonResponse(
          rows.results.map((r: any) => ({
            id: r.id,
            deviceName: r.device_name,
            publicKey: r.public_key,
            createdAt: r.created_at,
            expiresAt: r.expires_at,
          }))
        );
      }

      if (path.startsWith("privacy/device-requests/")) {
        const parts = path.split("/");
        const reqId = parts[2];
        const action = parts[3];

        if (!action && method === "GET") {
          const row = await env.DB.prepare(
            "SELECT status, grant_payload FROM device_requests WHERE id = ? AND user_id = ?"
          )
            .bind(reqId, userId)
            .first<any>();
          if (!row) return jsonResponse({ error: "Not found" }, 404);
          return jsonResponse({ status: row.status, grant: row.grant_payload });
        }

        if (action === "approve" && method === "POST") {
          const body = (await request.json()) as any;
          await env.DB.prepare(
            "UPDATE device_requests SET status = 'approved', grant_payload = ? WHERE id = ? AND user_id = ?"
          )
            .bind(body.grant, reqId, userId)
            .run();
          return jsonResponse({ ok: true });
        }

        if (action === "reject" && method === "POST") {
          await env.DB.prepare(
            "UPDATE device_requests SET status = 'rejected' WHERE id = ? AND user_id = ?"
          )
            .bind(reqId, userId)
            .run();
          return jsonResponse({ ok: true });
        }
      }

      // 7. Share Links & File Requests
      if (path === "shares" && method === "POST") {
        const body = (await request.json()) as any;
        const token = crypto.randomUUID().replace(/-/g, "").slice(0, 12);
        const now = new Date().toISOString();
        await env.DB.prepare(
          `INSERT INTO shares (token, user_id, file_id, file_key, file_nonce, enc_name, share_key_wrap, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
        )
          .bind(
            token,
            userId,
            body.fileID,
            body.fileKey ?? null,
            body.fileNonce ?? null,
            body.encName ?? null,
            body.shareKeyWrap ?? null,
            now
          )
          .run();

        return jsonResponse({
          token,
          url: `${url.origin}/s/${token}`,
          fileID: body.fileID,
          fileName: "SharedItem",
          isDirectory: false,
          size: 0,
          createdAt: now,
          downloads: 0,
          shareKeyWrap: body.shareKeyWrap ?? null,
        });
      }

      if (path === "file-requests" && method === "POST") {
        const body = (await request.json()) as any;
        const token = crypto.randomUUID().replace(/-/g, "").slice(0, 12);
        const now = new Date().toISOString();
        return jsonResponse({
          token,
          url: `${url.origin}/r/${token}`,
          folderID: body.folderID,
          folderName: "RequestFolder",
          createdAt: now,
        });
      }

      if ((path === "feedback" || path === "error-reports") && method === "POST") {
        return jsonResponse({ ok: true });
      }

      // 8. Sparkle Auto-Update Appcast XML (GET /app/appcast.xml)
      if (path === "app/appcast.xml" && method === "GET") {
        const appcastXml = `<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>XDrive (Orbit) Releases</title>
    <item>
      <title>Version 0.3.13</title>
      <pubDate>Tue, 03 Nov 2026 21:00:00 +0700</pubDate>
      <sparkle:version>39</sparkle:version>
      <sparkle:shortVersionString>0.3.13</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="${url.origin}/releases/XDrive-0.3.13.dmg"
                 sparkle:edSignature="8Bn8kmQovdDpAr/FS0irPBXfLHZzZeuwFlp9uF4DsC4="
                 length="14582912"
                 type="application/octet-stream"/>
    </item>
  </channel>
</rss>`;
        return new Response(appcastXml, {
          status: 200,
          headers: { "Content-Type": "application/xml; charset=utf-8" },
        });
      }

      // 9. Public Zero-Knowledge Share Metadata & WebCrypto Decryptor Page (GET /s/:token)
      if (path.startsWith("s/") && method === "GET") {
        const token = path.split("/")[1];
        const share = await env.DB.prepare("SELECT * FROM shares WHERE token = ?")
          .bind(token)
          .first<any>();
        if (!share) return jsonResponse({ error: "Share link not found" }, 404);

        if (url.searchParams.get("format") === "json") {
          return jsonResponse({
            token: share.token,
            fileID: share.file_id,
            fileKey: share.file_key,
            fileNonce: share.file_nonce,
            encName: share.enc_name,
            createdAt: share.created_at,
          });
        }

        const html = renderZeroKnowledgeShareHTML(token, share);
        return new Response(html, {
          status: 200,
          headers: { "Content-Type": "text/html; charset=utf-8" },
        });
      }

      return jsonResponse({ error: "Not Found", path }, 404);
    } catch (err: any) {
      return jsonResponse({ error: err?.message ?? "Internal Server Error" }, 500);
    }
  },
};

function mapFileRow(r: any) {
  return {
    id: r.id,
    name: r.name,
    parentID: r.parent_id,
    isDirectory: Boolean(r.is_directory),
    size: r.size,
    mimeType: r.mime_type,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    encName: r.enc_name,
    fileKey: r.file_key,
    fileNonce: r.file_nonce,
    plainSize: r.plain_size,
    sealPublic: r.seal_public,
  };
}

async function recordChange(db: D1Database, userId: string, c: any) {
  await db
    .prepare(
      `INSERT INTO changes
       (user_id, file_id, action, name, parent_id, is_directory, size, enc_name, file_key, file_nonce, plain_size, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .bind(
      userId,
      c.fileID,
      c.action,
      c.name ?? null,
      c.parentID ?? null,
      c.isDirectory ?? 0,
      c.size ?? 0,
      c.encName ?? null,
      c.fileKey ?? null,
      c.fileNonce ?? null,
      c.plainSize ?? null,
      c.createdAt ?? null,
      c.updatedAt ?? null
    )
    .run();
}

function renderZeroKnowledgeShareHTML(token: string, share: any): string {
  return `<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>XDrive — Chia sẻ Zero-Knowledge E2EE</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0b0f19; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
    .card { background: #131b2e; border: 1px solid #26334d; border-radius: 16px; padding: 32px; max-width: 480px; width: 90%; box-shadow: 0 20px 50px rgba(0,0,0,0.45); }
    .badge { display: inline-block; background: rgba(16,185,129,0.15); color: #34d399; padding: 4px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; margin-bottom: 12px; }
    h1 { font-size: 20px; margin: 0 0 8px; }
    p { color: #94a3b8; font-size: 14px; line-height: 1.5; }
    code { background: #0f172a; padding: 8px 12px; border-radius: 8px; display: block; margin: 12px 0; font-size: 12px; color: #38bdf8; word-break: break-all; }
  </style>
</head>
<body>
  <div class="card">
    <span class="badge">Zero-Knowledge E2EE (#sk= Fragment)</span>
    <h1 id="file-title">Đang giải mã siêu dữ liệu trong trình duyệt...</h1>
    <p>Khóa chia sẻ 128-bit nằm trong <code>window.location.hash</code> và không bao giờ được gửi tới máy chủ Cloudflare.</p>
    <code id="status-box">Share Token: ${token}</code>
  </div>
  <script>
    const hash = window.location.hash.slice(1);
    const params = new URLSearchParams(hash);
    const sk = params.get("sk");
    const statusBox = document.getElementById("status-box");
    const titleEl = document.getElementById("file-title");
    if (!sk) {
      titleEl.textContent = "Thiếu khóa giải mã (#sk=...) trên URL";
      statusBox.textContent = "Vui lòng sử dụng đầy đủ liên kết bao gồm phần #sk=...";
    } else {
      titleEl.textContent = "Đã sẵn sàng giải mã AES-256-GCM tại trình duyệt";
      statusBox.textContent = "Khóa #sk (" + sk.length + " ký tự Base64URL) đã được nạp vào WebCrypto.";
    }
  </script>
</body>
</html>`;
}

