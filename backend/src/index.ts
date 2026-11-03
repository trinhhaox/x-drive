import {
  renderFileRequestDropHTML,
  renderOAuthDesktopHTML,
  renderZeroKnowledgeShareHTML,
} from "./webViews.ts";

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

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256Base64Url(input: string): Promise<string> {
  const data = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return toBase64Url(new Uint8Array(digest));
}

async function ensureDefaultUser(db: D1Database, userId = "usr_default") {
  const now = new Date().toISOString();
  await db
    .prepare(
      `INSERT OR IGNORE INTO users (id, email, name, plan, storage_used, storage_limit, created_at)
       VALUES (?, 'mr.trinhhao@gmail.com', 'Trịnh Hảo', 'Cloudflare R2 (10 GB Miễn phí)', 0, 10737418240, ?)`
    )
    .bind(userId, now)
    .run();
}

async function resolveUserId(request: Request, env: Env): Promise<string> {
  const auth = request.headers.get("Authorization") ?? "";
  if (auth.startsWith("Bearer ")) {
    const token = auth.slice(7).trim();
    if (token) {
      const nowSec = Math.floor(Date.now() / 1000);
      const session = await env.DB.prepare(
        "SELECT user_id FROM sessions WHERE access_token = ? AND expires_at > ?"
      )
        .bind(token, nowSec)
        .first<{ user_id: string }>();
      if (session?.user_id) {
        return session.user_id;
      }
    }
  }
  const fallback = "usr_default";
  await ensureDefaultUser(env.DB, fallback);
  return fallback;
}

async function issueSession(
  db: D1Database,
  userId: string,
  deviceName = "Mac"
) {
  await ensureDefaultUser(db, userId);
  const accessToken = `at_${crypto.randomUUID().replace(/-/g, "")}`;
  const refreshToken = `rt_${crypto.randomUUID().replace(/-/g, "")}`;
  const nowSec = Math.floor(Date.now() / 1000);
  const expiresIn = 3600 * 24;
  await db
    .prepare(
      `INSERT INTO sessions (access_token, refresh_token, user_id, device_name, expires_at, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
    .bind(
      accessToken,
      refreshToken,
      userId,
      deviceName,
      nowSec + expiresIn,
      nowSec
    )
    .run();

  const u = await db
    .prepare("SELECT * FROM users WHERE id = ?")
    .bind(userId)
    .first<any>();

  return {
    accessToken,
    refreshToken,
    expiresIn,
    user: {
      id: userId,
      email: u?.email ?? "mr.trinhhao@gmail.com",
      name: u?.name ?? "Trịnh Hảo",
      plan: u?.plan ?? "Pro 2 TB",
      storageUsed: u?.storage_used ?? 0,
      storageLimit: u?.storage_limit ?? 2_199_023_255_552,
    },
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return jsonResponse({ ok: true });
    }

    const url = new URL(request.url);
    const rawPath = url.pathname.replace(/^\/+/, "").replace(/\/+$/, "");
    // Support both `/files` and `/api/files` prefixes seamlessly
    const path = rawPath.startsWith("api/") ? rawPath.slice(4) : rawPath;
    const method = request.method.toUpperCase();

    try {
      // 0. Health Check
      if ((path === "" || path === "health") && method === "GET") {
        return jsonResponse({
          service: "xdrive-orbit-api",
          version: "0.3.15",
          status: "healthy",
          features: [
            "FSKit-1MiB-Range",
            "ZeroKnowledge-AES256GCM",
            "ECDH-P256-DeviceApproval",
            "R2-MultipartUploads",
            "WebCrypto-ShareDecryptor",
          ],
        });
      }

      // 1. Auth Endpoints (OAuth2 PKCE Desktop + Apple + Refresh + Logout)
      if (path === "auth/desktop" && method === "GET") {
        const challenge = url.searchParams.get("code_challenge") ?? "";
        const challengeMethod =
          url.searchParams.get("code_challenge_method") ?? "S256";
        const redirectUri =
          url.searchParams.get("redirect_uri") ?? "orbit://auth";
        const userId = "usr_default";
        await ensureDefaultUser(env.DB, userId);

        const code = `cd_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`;
        const expiresAt = Math.floor(Date.now() / 1000) + 600;
        await env.DB.prepare(
          `INSERT INTO pkce_codes (code, user_id, code_challenge, code_challenge_method, expires_at)
           VALUES (?, ?, ?, ?, ?)`
        )
          .bind(code, userId, challenge, challengeMethod, expiresAt)
          .run();

        const html = renderOAuthDesktopHTML(
          code,
          redirectUri,
          "mr.trinhhao@gmail.com"
        );
        return new Response(html, {
          status: 200,
          headers: { "Content-Type": "text/html; charset=utf-8" },
        });
      }

      if (path === "auth/browser/exchange" && method === "POST") {
        const body = (await request.json().catch(() => ({}))) as any;
        const code = body.code as string | undefined;
        const verifier = body.verifier as string | undefined;
        let userId = "usr_default";

        if (code) {
          const pkceRow = await env.DB.prepare(
            "SELECT * FROM pkce_codes WHERE code = ?"
          )
            .bind(code)
            .first<any>();

          if (pkceRow) {
            await env.DB.prepare("DELETE FROM pkce_codes WHERE code = ?")
              .bind(code)
              .run();
            if (pkceRow.code_challenge && verifier) {
              const computedChallenge = await sha256Base64Url(verifier);
              if (computedChallenge !== pkceRow.code_challenge) {
                return jsonResponse(
                  { error: "PKCE S256 verification failed" },
                  401
                );
              }
            }
            userId = pkceRow.user_id;
          }
        }

        const session = await issueSession(
          env.DB,
          userId,
          body.deviceName ?? "Mac"
        );
        return jsonResponse(session);
      }

      if (path === "auth/apple" && method === "POST") {
        const body = (await request.json().catch(() => ({}))) as any;
        const session = await issueSession(
          env.DB,
          "usr_default",
          body.deviceName ?? "Mac"
        );
        return jsonResponse(session);
      }

      if (path === "auth/refresh" && method === "POST") {
        const body = (await request.json().catch(() => ({}))) as any;
        let userId = "usr_default";
        if (body.refreshToken) {
          const row = await env.DB.prepare(
            "SELECT user_id FROM sessions WHERE refresh_token = ?"
          )
            .bind(body.refreshToken)
            .first<{ user_id: string }>();
          if (row?.user_id) userId = row.user_id;
        }
        const session = await issueSession(env.DB, userId);
        return jsonResponse(session);
      }

      if (path === "auth/logout" && method === "POST") {
        const auth = request.headers.get("Authorization") ?? "";
        if (auth.startsWith("Bearer ")) {
          const token = auth.slice(7).trim();
          await env.DB.prepare("DELETE FROM sessions WHERE access_token = ?")
            .bind(token)
            .run();
        }
        return jsonResponse({ ok: true });
      }

      // Resolve authenticated user for protected routes
      const userId = await resolveUserId(request, env);

      // 2. User Profile & Quota
      if (path === "me" && method === "GET") {
        const u = await env.DB.prepare("SELECT * FROM users WHERE id = ?")
          .bind(userId)
          .first<any>();
        return jsonResponse({
          id: userId,
          email: u?.email ?? "mr.trinhhao@gmail.com",
          name: u?.name ?? "Trịnh Hảo",
          plan: u?.plan ?? "Cloudflare R2 (10 GB Miễn phí)",
          storageUsed: u?.storage_used ?? 0,
          storageLimit: u?.storage_limit ?? 10_737_418_240,
        });
      }

      if (path === "quota" && method === "GET") {
        const stats = await env.DB.prepare(
          "SELECT COALESCE(SUM(COALESCE(plain_size, size)), 0) AS used, COUNT(*) AS cnt FROM files WHERE user_id = ? AND deleted = 0"
        )
          .bind(userId)
          .first<{ used: number; cnt: number }>();

        const u = await env.DB.prepare("SELECT * FROM users WHERE id = ?")
          .bind(userId)
          .first<any>();

        const usedBytes = stats?.used ?? 0;
        await env.DB.prepare("UPDATE users SET storage_used = ? WHERE id = ?")
          .bind(usedBytes, userId)
          .run();

        return jsonResponse({
          usedBytes,
          limitBytes: u?.storage_limit ?? 10_737_418_240,
          plan: u?.plan ?? "Cloudflare R2 (10 GB Miễn phí)",
          fileCount: stats?.cnt ?? 0,
        });
      }

      if ((path === "user/plan" || path === "quota/plan") && (method === "POST" || method === "PATCH")) {
        const body = (await request.json()) as any;
        const limitBytes = Number(body.limitBytes ?? 10_737_418_240);
        const plan = String(body.plan ?? "Cloudflare R2 (10 GB Miễn phí)");
        await ensureDefaultUser(env.DB, userId);
        await env.DB.prepare(
          "UPDATE users SET storage_limit = ?, plan = ? WHERE id = ?"
        )
          .bind(limitBytes, plan, userId)
          .run();

        return jsonResponse({ ok: true, limitBytes, plan });
      }

      // 3. Directory Listing, All Files, Path Lookup & Delta Changes
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

      if (path === "files/lookup" && method === "GET") {
        const nameHash = url.searchParams.get("nameHash");
        const name = url.searchParams.get("name");
        const parentID = url.searchParams.get("parentID");

        let row: any = null;
        if (nameHash) {
          row = parentID
            ? await env.DB.prepare(
                "SELECT * FROM files WHERE user_id = ? AND parent_id = ? AND name_hash = ? AND deleted = 0"
              )
                .bind(userId, parentID, nameHash)
                .first()
            : await env.DB.prepare(
                "SELECT * FROM files WHERE user_id = ? AND parent_id IS NULL AND name_hash = ? AND deleted = 0"
              )
                .bind(userId, nameHash)
                .first();
        } else if (name) {
          row = parentID
            ? await env.DB.prepare(
                "SELECT * FROM files WHERE user_id = ? AND parent_id = ? AND name = ? AND deleted = 0"
              )
                .bind(userId, parentID, name)
                .first()
            : await env.DB.prepare(
                "SELECT * FROM files WHERE user_id = ? AND parent_id IS NULL AND name = ? AND deleted = 0"
              )
                .bind(userId, name)
                .first();
        }
        if (!row) return jsonResponse({ error: "Not found" }, 404);
        return jsonResponse(mapFileRow(row));
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
        const cursor =
          changes.length > 0 ? changes[changes.length - 1].seq : since;
        return jsonResponse({
          changes,
          cursor,
          hasMore: changes.length === 500,
        });
      }

      // 4. Create Folder, Direct Upload & R2 Multipart Upload Engine
      if (path === "files/folder" && method === "POST") {
        const body = (await request.json()) as any;
        const parentID = body.parentID ?? null;
        const nameHash = body.nameHash ?? null;

        // Enforce Blind-Index uniqueness if E2EE nameHash is provided
        if (nameHash) {
          const dup = parentID
            ? await env.DB.prepare(
                "SELECT id FROM files WHERE user_id = ? AND parent_id = ? AND name_hash = ? AND deleted = 0"
              )
                .bind(userId, parentID, nameHash)
                .first()
            : await env.DB.prepare(
                "SELECT id FROM files WHERE user_id = ? AND parent_id IS NULL AND name_hash = ? AND deleted = 0"
              )
                .bind(userId, nameHash)
                .first();
          if (dup) {
            return jsonResponse(
              { error: "Duplicate encrypted name_hash in directory" },
              409
            );
          }
        }

        const id = `dir_${crypto.randomUUID()}`;
        const now = new Date().toISOString();
        await env.DB.prepare(
          `INSERT INTO files (id, user_id, parent_id, name, is_directory, size, enc_name, name_hash, created_at, updated_at)
           VALUES (?, ?, ?, ?, 1, 0, ?, ?, ?, ?)`
        )
          .bind(
            id,
            userId,
            parentID,
            body.name ?? "folder",
            body.encName ?? null,
            nameHash,
            now,
            now
          )
          .run();

        await recordChange(env.DB, userId, {
          fileID: id,
          action: "upsert",
          name: body.name ?? "folder",
          parentID,
          isDirectory: 1,
          size: 0,
          encName: body.encName ?? null,
          createdAt: now,
          updatedAt: now,
        });

        return jsonResponse({
          id,
          name: body.name ?? "folder",
          parentID,
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

        // Check user storage quota before writing
        const u = await env.DB.prepare(
          "SELECT storage_used, storage_limit FROM users WHERE id = ?"
        )
          .bind(userId)
          .first<{ storage_used: number; storage_limit: number }>();
        if (
          u &&
          u.storage_used + blob.byteLength > u.storage_limit
        ) {
          return jsonResponse({ error: "Storage quota exceeded" }, 507);
        }

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
          parentID,
          isDirectory: false,
          size: blob.byteLength,
          createdAt: now,
          updatedAt: now,
          encName,
          fileKey,
          fileNonce,
          plainSize,
        });
      }

      // 4b. R2 Multipart Uploads (for Large Lane > 4 MiB files)
      if (path === "files/multipart/start" && method === "POST") {
        const body = (await request.json()) as any;
        const uploadId = `mpu_${crypto.randomUUID().replace(/-/g, "")}`;
        const fileId = body.fileID ?? `file_${crypto.randomUUID()}`;
        const r2Key = `${userId}/${fileId}`;
        const r2Multipart = await env.BUCKET.createMultipartUpload(r2Key);
        const now = new Date().toISOString();

        await env.DB.prepare(
          `INSERT INTO multipart_uploads
           (upload_id, file_id, user_id, r2_key, r2_upload_id, name, parent_id, size, enc_name, name_hash, file_key, file_nonce, plain_size, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
          .bind(
            uploadId,
            fileId,
            userId,
            r2Key,
            r2Multipart.uploadId,
            body.name ?? "large-file",
            body.parentID ?? null,
            body.size ?? 0,
            body.encName ?? null,
            body.nameHash ?? null,
            body.fileKey ?? null,
            body.fileNonce ?? null,
            body.plainSize ?? null,
            now
          )
          .run();

        return jsonResponse({
          uploadID: uploadId,
          fileID: fileId,
          partSize: 4 * 1024 * 1024,
        });
      }

      if (path === "files/multipart/presign" && method === "POST") {
        const body = (await request.json()) as any;
        const uploadId = body.uploadID as string;
        const partNumbers = (body.partNumbers as number[]) ?? [1];
        const urls: Record<string, string> = {};
        for (const p of partNumbers) {
          urls[String(p)] = `${url.origin}/files/multipart/${uploadId}/${p}`;
        }
        return jsonResponse({ urls });
      }

      if (path.startsWith("files/multipart/") && method === "PUT") {
        const parts = path.split("/");
        const uploadId = parts[2];
        const partNumber = Number(parts[3] ?? "1");

        const mpuRow = await env.DB.prepare(
          "SELECT * FROM multipart_uploads WHERE upload_id = ? AND user_id = ?"
        )
          .bind(uploadId, userId)
          .first<any>();
        if (!mpuRow) return jsonResponse({ error: "Upload session not found" }, 404);

        const data = await request.arrayBuffer();
        const r2Mpu = env.BUCKET.resumeMultipartUpload(
          mpuRow.r2_key,
          mpuRow.r2_upload_id
        );
        const uploadedPart = await r2Mpu.uploadPart(partNumber, data);

        return new Response(null, {
          status: 200,
          headers: {
            ETag: uploadedPart.etag,
            "Access-Control-Expose-Headers": "ETag",
          },
        });
      }

      if (path === "files/multipart/complete" && method === "POST") {
        const body = (await request.json()) as any;
        const uploadId = body.uploadID as string;
        const parts = (body.parts as Array<{ partNumber: number; etag: string }>) ?? [];

        const mpuRow = await env.DB.prepare(
          "SELECT * FROM multipart_uploads WHERE upload_id = ? AND user_id = ?"
        )
          .bind(uploadId, userId)
          .first<any>();
        if (!mpuRow) return jsonResponse({ error: "Upload session not found" }, 404);

        const r2Mpu = env.BUCKET.resumeMultipartUpload(
          mpuRow.r2_key,
          mpuRow.r2_upload_id
        );
        await r2Mpu.complete(parts);

        const now = new Date().toISOString();
        await env.DB.prepare(
          `INSERT OR REPLACE INTO files
           (id, user_id, parent_id, name, is_directory, size, enc_name, name_hash, file_key, file_nonce, plain_size, deleted, created_at, updated_at)
           VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, 0, ?, ?)`
        )
          .bind(
            mpuRow.file_id,
            userId,
            mpuRow.parent_id,
            mpuRow.name,
            mpuRow.size,
            mpuRow.enc_name,
            mpuRow.name_hash,
            mpuRow.file_key,
            mpuRow.file_nonce,
            mpuRow.plain_size,
            now,
            now
          )
          .run();

        await env.DB.prepare("DELETE FROM multipart_uploads WHERE upload_id = ?")
          .bind(uploadId)
          .run();

        await recordChange(env.DB, userId, {
          fileID: mpuRow.file_id,
          action: "upsert",
          name: mpuRow.name,
          parentID: mpuRow.parent_id,
          isDirectory: 0,
          size: mpuRow.size,
          encName: mpuRow.enc_name,
          fileKey: mpuRow.file_key,
          fileNonce: mpuRow.file_nonce,
          plainSize: mpuRow.plain_size,
          createdAt: now,
          updatedAt: now,
        });

        return jsonResponse({
          id: mpuRow.file_id,
          name: mpuRow.name,
          parentID: mpuRow.parent_id,
          isDirectory: false,
          size: mpuRow.size,
          createdAt: now,
          updatedAt: now,
          encName: mpuRow.enc_name,
          fileKey: mpuRow.file_key,
          fileNonce: mpuRow.file_nonce,
          plainSize: mpuRow.plain_size,
        });
      }

      if (path === "files/multipart/abort" && method === "POST") {
        const body = (await request.json()) as any;
        const uploadId = body.uploadID as string;
        const mpuRow = await env.DB.prepare(
          "SELECT * FROM multipart_uploads WHERE upload_id = ? AND user_id = ?"
        )
          .bind(uploadId, userId)
          .first<any>();
        if (mpuRow) {
          const r2Mpu = env.BUCKET.resumeMultipartUpload(
            mpuRow.r2_key,
            mpuRow.r2_upload_id
          );
          await r2Mpu.abort();
          await env.DB.prepare("DELETE FROM multipart_uploads WHERE upload_id = ?")
            .bind(uploadId)
            .run();
        }
        return jsonResponse({ ok: true });
      }

      // 5. Batch Content URLs & Individual File Operations (/files/:id...)
      if (path === "files/content-urls" && method === "POST") {
        const body = (await request.json()) as { ids?: string[] };
        const urls: Record<string, string> = {};
        for (const id of body.ids ?? []) {
          urls[id] = `${url.origin}/files/${id}/content`;
        }
        return jsonResponse({ urls });
      }

      if (path.startsWith("files/")) {
        const segments = path.split("/");
        const fileId = segments[1];
        const subAction = segments[2];

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
          const now = new Date().toISOString();
          await env.DB.prepare(
            `UPDATE files SET
               name = COALESCE(?, name),
               parent_id = COALESCE(?, parent_id),
               enc_name = COALESCE(?, enc_name),
               name_hash = COALESCE(?, name_hash),
               updated_at = ?
             WHERE id = ? AND user_id = ?`
          )
            .bind(
              body.name ?? null,
              body.parentID ?? null,
              body.encName ?? null,
              body.nameHash ?? null,
              now,
              fileId,
              userId
            )
            .run();

          const updated = await env.DB.prepare(
            "SELECT * FROM files WHERE id = ? AND user_id = ?"
          )
            .bind(fileId, userId)
            .first<any>();

          if (updated) {
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
              updatedAt: now,
            });
          }
          return jsonResponse(updated ? mapFileRow(updated) : { ok: true });
        }

        if (!subAction && method === "DELETE") {
          await env.DB.prepare(
            "UPDATE files SET deleted = 1, updated_at = ? WHERE id = ? AND user_id = ?"
          )
            .bind(new Date().toISOString(), fileId, userId)
            .run();
          await env.BUCKET.delete(`${userId}/${fileId}`);
          await recordChange(env.DB, userId, {
            fileID: fileId,
            action: "delete",
          });
          return jsonResponse({ ok: true });
        }

        if (subAction === "content-url" && method === "GET") {
          return jsonResponse({ url: `${url.origin}/files/${fileId}/content` });
        }

        if (subAction === "content" && method === "GET") {
          const rangeHeader = request.headers.get("Range");
          if (rangeHeader && rangeHeader.startsWith("bytes=")) {
            const [startStr, endStr] = rangeHeader
              .replace("bytes=", "")
              .split("-");
            const start = Number(startStr);
            const end = Number(endStr);
            const length = end - start + 1;
            const obj = await env.BUCKET.get(`${userId}/${fileId}`, {
              range: { offset: start, length },
            });
            if (!obj) return new Response("Not Found", { status: 404 });
            return new Response(obj.body, {
              status: 206,
              headers: {
                "Content-Range": `bytes ${start}-${end}/${obj.size}`,
                "Content-Length": String(length),
                "Accept-Ranges": "bytes",
              },
            });
          }
          const obj = await env.BUCKET.get(`${userId}/${fileId}`);
          if (!obj) return new Response("Not Found", { status: 404 });
          return new Response(obj.body, {
            status: 200,
            headers: { "Accept-Ranges": "bytes" },
          });
        }

        if (subAction === "encrypted-content" && method === "PUT") {
          const fileKey = url.searchParams.get("fileKey");
          const fileNonce = url.searchParams.get("fileNonce");
          const plainSize = Number(url.searchParams.get("plainSize") ?? "0");
          const blob = await request.arrayBuffer();
          await env.BUCKET.put(`${userId}/${fileId}`, blob);
          await env.DB.prepare(
            `UPDATE files SET size = ?, file_key = ?, file_nonce = ?, plain_size = ?, seal_public = NULL, updated_at = ?
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

      if (path === "privacy/rewrap-files" && method === "POST") {
        const entries = (await request.json()) as any[];
        for (const e of entries) {
          await env.DB.prepare(
            `UPDATE files SET file_key = ?, seal_public = NULL WHERE id = ? AND user_id = ?`
          )
            .bind(e.fileKey, e.id, userId)
            .run();
        }
        return jsonResponse({ ok: true });
      }

      if (path === "privacy/rewrap-shares" && method === "POST") {
        const entries = (await request.json()) as any[];
        for (const e of entries) {
          await env.DB.prepare(
            `UPDATE shares SET share_key_wrap = ? WHERE token = ? AND user_id = ?`
          )
            .bind(e.shareKeyWrap, e.token, userId)
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

        const fileRow = await env.DB.prepare(
          "SELECT name, is_directory, size FROM files WHERE id = ? AND user_id = ?"
        )
          .bind(body.fileID, userId)
          .first<any>();

        return jsonResponse({
          token,
          url: `${url.origin}/s/${token}`,
          fileID: body.fileID,
          fileName: fileRow?.name ?? "SharedItem",
          isDirectory: Boolean(fileRow?.is_directory),
          size: fileRow?.size ?? 0,
          createdAt: now,
          downloads: 0,
          shareKeyWrap: body.shareKeyWrap ?? null,
        });
      }

      if (path === "shares" && method === "GET") {
        const rows = await env.DB.prepare(
          `SELECT s.*, f.name AS file_name, f.is_directory, f.size
           FROM shares s
           LEFT JOIN files f ON f.id = s.file_id
           WHERE s.user_id = ?
           ORDER BY s.created_at DESC`
        )
          .bind(userId)
          .all();

        return jsonResponse(
          rows.results.map((r: any) => ({
            token: r.token,
            url: `${url.origin}/s/${r.token}`,
            fileID: r.file_id,
            fileName: r.file_name ?? "SharedItem",
            isDirectory: Boolean(r.is_directory),
            size: r.size ?? 0,
            createdAt: r.created_at,
            downloads: r.downloads ?? 0,
            shareKeyWrap: r.share_key_wrap ?? null,
          }))
        );
      }

      if (path.startsWith("shares/") && method === "DELETE") {
        const targetIdOrToken = path.split("/")[1];
        await env.DB.prepare(
          "DELETE FROM shares WHERE user_id = ? AND (file_id = ? OR token = ?)"
        )
          .bind(userId, targetIdOrToken, targetIdOrToken)
          .run();
        return jsonResponse({ ok: true });
      }

      if (path === "file-requests" && method === "POST") {
        const body = (await request.json()) as any;
        const token = crypto.randomUUID().replace(/-/g, "").slice(0, 12);
        const now = new Date().toISOString();

        const u = await env.DB.prepare(
          "SELECT drop_public FROM users WHERE id = ?"
        )
          .bind(userId)
          .first<{ drop_public: string | null }>();

        const folderRow = await env.DB.prepare(
          "SELECT name FROM files WHERE id = ? AND user_id = ?"
        )
          .bind(body.folderID, userId)
          .first<{ name: string }>();

        const folderName =
          body.folderName ?? folderRow?.name ?? "RequestFolder";

        await env.DB.prepare(
          `INSERT INTO file_requests (token, user_id, folder_id, folder_name, drop_public, created_at)
           VALUES (?, ?, ?, ?, ?, ?)`
        )
          .bind(
            token,
            userId,
            body.folderID,
            folderName,
            u?.drop_public ?? null,
            now
          )
          .run();

        return jsonResponse({
          token,
          url: `${url.origin}/r/${token}`,
          folderID: body.folderID,
          folderName,
          createdAt: now,
        });
      }

      // 8. Diagnostics & Feedback
      if (path === "feedback" && method === "POST") {
        const body = (await request.json().catch(() => ({}))) as any;
        const id = `fb_${crypto.randomUUID().slice(0, 10)}`;
        await env.DB.prepare(
          `INSERT INTO error_reports (id, user_id, component, code, message, app_version, os_version, details_json, created_at)
           VALUES (?, ?, 'UserFeedback', ?, ?, ?, ?, ?, ?)`
        )
          .bind(
            id,
            userId,
            body.category ?? "feedback",
            body.message ?? "",
            body.appVersion ?? "0.3.14",
            body.osVersion ?? "macOS",
            JSON.stringify(body),
            new Date().toISOString()
          )
          .run();
        return jsonResponse({ ok: true, id });
      }

      if (path === "error-reports" && method === "POST") {
        const body = (await request.json().catch(() => ({}))) as any;
        const id = `err_${crypto.randomUUID().slice(0, 10)}`;
        await env.DB.prepare(
          `INSERT INTO error_reports (id, user_id, component, code, message, app_version, os_version, details_json, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
          .bind(
            id,
            userId,
            body.component ?? "OrbitCore",
            body.code ?? "diagnostic",
            body.message ?? "",
            body.appVersion ?? "0.3.14",
            body.osVersion ?? "macOS",
            JSON.stringify(body.details ?? {}),
            new Date().toISOString()
          )
          .run();
        return jsonResponse({ ok: true, id });
      }

      // 9. Sparkle Auto-Update Appcast XML (GET /app/appcast.xml)
      if (path === "app/appcast.xml" && method === "GET") {
        const appcastXml = `<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>XDrive (Orbit) Releases</title>
    <item>
      <title>Version 0.3.15</title>
      <pubDate>Tue, 03 Nov 2026 23:58:00 +0700</pubDate>
      <sparkle:version>41</sparkle:version>
      <sparkle:shortVersionString>0.3.15</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/trinhhaox/x-drive/releases/download/v0.3.15/XDrive-0.3.15.dmg"
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

      // 10. Public Zero-Knowledge Share Viewer & Blob Download (GET /s/:token & GET /s/:token/download)
      if (path.startsWith("s/")) {
        const parts = path.split("/");
        const token = parts[1];
        const sub = parts[2];

        const share = await env.DB.prepare(
          `SELECT s.*, f.name AS plain_name, f.size, f.plain_size
           FROM shares s
           LEFT JOIN files f ON f.id = s.file_id
           WHERE s.token = ?`
        )
          .bind(token)
          .first<any>();
        if (!share)
          return jsonResponse({ error: "Share link not found" }, 404);

        if (sub === "download" && method === "GET") {
          const obj = await env.BUCKET.get(
            `${share.user_id}/${share.file_id}`
          );
          if (!obj) return new Response("File blob not found", { status: 404 });
          await env.DB.prepare(
            "UPDATE shares SET downloads = downloads + 1 WHERE token = ?"
          )
            .bind(token)
            .run();
          return new Response(obj.body, {
            status: 200,
            headers: {
              "Content-Type": "application/octet-stream",
              "Cache-Control": "no-store",
            },
          });
        }

        if (!sub && method === "GET") {
          if (url.searchParams.get("format") === "json") {
            return jsonResponse({
              token: share.token,
              fileID: share.file_id,
              fileKey: share.file_key,
              fileNonce: share.file_nonce,
              encName: share.enc_name,
              size: share.size ?? 0,
              plainSize: share.plain_size ?? share.size ?? 0,
              createdAt: share.created_at,
            });
          }

          const html = renderZeroKnowledgeShareHTML(token, share);
          return new Response(html, {
            status: 200,
            headers: { "Content-Type": "text/html; charset=utf-8" },
          });
        }
      }

      // 11. Public File Request Drop Portal & Upload (GET /r/:token & POST /r/:token/upload)
      if (path.startsWith("r/")) {
        const parts = path.split("/");
        const token = parts[1];
        const sub = parts[2];

        const reqRow = await env.DB.prepare(
          "SELECT * FROM file_requests WHERE token = ?"
        )
          .bind(token)
          .first<any>();
        if (!reqRow)
          return jsonResponse({ error: "File request not found" }, 404);

        if (!sub && method === "GET") {
          const html = renderFileRequestDropHTML(token, reqRow);
          return new Response(html, {
            status: 200,
            headers: { "Content-Type": "text/html; charset=utf-8" },
          });
        }

        if (sub === "upload" && method === "POST") {
          const fileName = url.searchParams.get("name") ?? "DroppedFile.bin";
          const sealPublic = url.searchParams.get("sealPublic");
          const fileKey = url.searchParams.get("fileKey");
          const fileNonce = url.searchParams.get("fileNonce");
          const encName = url.searchParams.get("encName");
          const plainSize = url.searchParams.get("plainSize")
            ? Number(url.searchParams.get("plainSize"))
            : null;

          const blob = await request.arrayBuffer();
          const newFileId = `file_${crypto.randomUUID()}`;
          await env.BUCKET.put(`${reqRow.user_id}/${newFileId}`, blob);

          const now = new Date().toISOString();
          await env.DB.prepare(
            `INSERT INTO files
             (id, user_id, parent_id, name, is_directory, size, enc_name, file_key, file_nonce, plain_size, seal_public, deleted, created_at, updated_at)
             VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, 0, ?, ?)`
          )
            .bind(
              newFileId,
              reqRow.user_id,
              reqRow.folder_id,
              fileName,
              blob.byteLength,
              encName ?? null,
              fileKey ?? null,
              fileNonce ?? null,
              plainSize ?? blob.byteLength,
              sealPublic ?? null,
              now,
              now
            )
            .run();

          await env.DB.prepare(
            "UPDATE file_requests SET uploads_count = uploads_count + 1 WHERE token = ?"
          )
            .bind(token)
            .run();

          await recordChange(env.DB, reqRow.user_id, {
            fileID: newFileId,
            action: "upsert",
            name: fileName,
            parentID: reqRow.folder_id,
            isDirectory: 0,
            size: blob.byteLength,
            encName: encName ?? null,
            fileKey: fileKey ?? null,
            fileNonce: fileNonce ?? null,
            plainSize: plainSize ?? blob.byteLength,
            sealPublic: sealPublic ?? null,
            createdAt: now,
            updatedAt: now,
          });

          return jsonResponse({ ok: true, fileID: newFileId });
        }
      }

      return jsonResponse({ error: "Not Found", path }, 404);
    } catch (err: any) {
      return jsonResponse(
        { error: err?.message ?? "Internal Server Error" },
        500
      );
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
       (user_id, file_id, action, name, parent_id, is_directory, size, enc_name, file_key, file_nonce, plain_size, seal_public, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
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
      c.sealPublic ?? null,
      c.createdAt ?? null,
      c.updatedAt ?? null
    )
    .run();
}
