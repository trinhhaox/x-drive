import assert from "node:assert/strict";
import { describe, it } from "node:test";
import worker from "../src/index.ts";
import { createLocalEnv } from "../src/localRuntime.ts";

function toBase64Url(bytes) {
  return Buffer.from(bytes)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function sha256Base64Url(str) {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(str)
  );
  return toBase64Url(new Uint8Array(digest));
}

describe("XDrive Cloudflare Workers + D1 + R2 Backend Suite", () => {
  it("1. Health check and Sparkle Appcast XML", async () => {
    const env = createLocalEnv();
    const healthRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/health"),
      env
    );
    assert.equal(healthRes.status, 200);
    const health = await healthRes.json();
    assert.equal(health.service, "xdrive-orbit-api");
    assert.equal(health.status, "healthy");

    const appcastRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/app/appcast.xml"),
      env
    );
    assert.equal(appcastRes.status, 200);
    const xml = await appcastRes.text();
    assert.ok(xml.includes("sparkle:shortVersionString>0.3.15<"));
  });

  it("2. OAuth2 PKCE (S256) authentication & Bearer session enforcement", async () => {
    const env = createLocalEnv();
    const verifier = "pkce_secret_verifier_value_for_xdrive_macos_client_12345";
    const challenge = await sha256Base64Url(verifier);

    const desktopRes = await worker.fetch(
      new Request(
        `http://127.0.0.1:8787/auth/desktop?code_challenge=${challenge}&code_challenge_method=S256&redirect_uri=orbit://auth`
      ),
      env
    );
    assert.equal(desktopRes.status, 200);
    const html = await desktopRes.text();
    const match = html.match(/orbit:\/\/auth\?code=(cd_[a-zA-Z0-9]+)/);
    assert.ok(match, "Desktop OAuth HTML should include authorization code");
    const authCode = match[1];

    // Exchange with valid PKCE verifier
    const exchRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/auth/browser/exchange", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          code: authCode,
          verifier,
          deviceName: "MacBook Pro M4",
        }),
      }),
      env
    );
    assert.equal(exchRes.status, 200);
    const session = await exchRes.json();
    assert.ok(session.accessToken.startsWith("at_"));
    assert.ok(session.refreshToken.startsWith("rt_"));

    // Verify /me with Bearer token
    const meRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/me", {
        headers: { Authorization: `Bearer ${session.accessToken}` },
      }),
      env
    );
    assert.equal(meRes.status, 200);
    const me = await meRes.json();
    assert.equal(me.email, "mr.trinhhao@gmail.com");
  });

  it("3. Folder creation, Blind-Index name_hash uniqueness (409), and Lookup", async () => {
    const env = createLocalEnv();

    const createRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/files/folder", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "e1:encrypted_folder_name",
          encName: "e1:encrypted_folder_name",
          nameHash: "hmac_blind_index_abc123",
        }),
      }),
      env
    );
    assert.equal(createRes.status, 200);
    const folder = await createRes.json();
    assert.ok(folder.id.startsWith("dir_"));

    // Duplicate name_hash in same parent must return 409 Conflict
    const dupRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/files/folder", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "e1:another_ciphertext_same_name",
          encName: "e1:another_ciphertext_same_name",
          nameHash: "hmac_blind_index_abc123",
        }),
      }),
      env
    );
    assert.equal(dupRes.status, 409);

    // Lookup by blind index nameHash
    const lookupRes = await worker.fetch(
      new Request(
        "http://127.0.0.1:8787/files/lookup?nameHash=hmac_blind_index_abc123"
      ),
      env
    );
    assert.equal(lookupRes.status, 200);
    const lookedUp = await lookupRes.json();
    assert.equal(lookedUp.id, folder.id);
  });

  it("4. File Upload, HTTP 206 Partial Range Streaming, and Delta Changes", async () => {
    const env = createLocalEnv();
    const payload = new TextEncoder().encode(
      "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    );

    const upRes = await worker.fetch(
      new Request(
        "http://127.0.0.1:8787/files/upload?name=RangeTest.bin&plainSize=62",
        {
          method: "POST",
          body: payload,
        }
      ),
      env
    );
    assert.equal(upRes.status, 200);
    const fileItem = await upRes.json();

    // Request bytes 10-25 (inclusive -> 16 bytes: "ABCDEFGHIJKLMNOP")
    const rangeRes = await worker.fetch(
      new Request(`http://127.0.0.1:8787/files/${fileItem.id}/content`, {
        headers: { Range: "bytes=10-25" },
      }),
      env
    );
    assert.equal(rangeRes.status, 206);
    assert.equal(rangeRes.headers.get("Content-Range"), "bytes 10-25/62");
    const sliceText = await rangeRes.text();
    assert.equal(sliceText, "ABCDEFGHIJKLMNOP");

    // Verify Delta Change Log recorded the upsert
    const changesRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/changes?since=0"),
      env
    );
    assert.equal(changesRes.status, 200);
    const delta = await changesRes.json();
    assert.equal(delta.changes.length, 1);
    assert.equal(delta.changes[0].fileID, fileItem.id);
    assert.equal(delta.changes[0].action, "upsert");
  });

  it("5. R2 Multipart Upload lifecycle (start -> presign -> upload parts -> complete)", async () => {
    const env = createLocalEnv();

    const startRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/files/multipart/start", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "LargeVideo.mov",
          size: 20,
          plainSize: 20,
        }),
      }),
      env
    );
    assert.equal(startRes.status, 200);
    const { uploadID, fileID } = await startRes.json();

    const presignRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/files/multipart/presign", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ uploadID, partNumbers: [1, 2] }),
      }),
      env
    );
    const { urls } = await presignRes.json();
    assert.ok(urls["1"] && urls["2"]);

    const part1Res = await worker.fetch(
      new Request(urls["1"], {
        method: "PUT",
        body: new TextEncoder().encode("PART_ONE__"),
      }),
      env
    );
    assert.equal(part1Res.status, 200);
    const etag1 = part1Res.headers.get("ETag");

    const part2Res = await worker.fetch(
      new Request(urls["2"], {
        method: "PUT",
        body: new TextEncoder().encode("PART_TWO!!"),
      }),
      env
    );
    assert.equal(part2Res.status, 200);
    const etag2 = part2Res.headers.get("ETag");

    const compRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/files/multipart/complete", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          uploadID,
          parts: [
            { partNumber: 1, etag: etag1 },
            { partNumber: 2, etag: etag2 },
          ],
        }),
      }),
      env
    );
    assert.equal(compRes.status, 200);

    // Read full assembled file
    const getRes = await worker.fetch(
      new Request(`http://127.0.0.1:8787/files/${fileID}/content`),
      env
    );
    assert.equal(await getRes.text(), "PART_ONE__PART_TWO!!");
  });

  it("6. Zero-Knowledge E2EE Privacy Sweep & ECDH P-256 Device Approval", async () => {
    const env = createLocalEnv();

    // Enable privacy
    await worker.fetch(
      new Request("http://127.0.0.1:8787/privacy/enable", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          keyCheck: "kc_sample",
          dropPublic: "pub_p256_x963",
          dropPrivateWrap: "priv_wrapped",
        }),
      }),
      env
    );

    // Request device approval
    const reqRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/privacy/device-requests", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          deviceName: "iPad Pro M4",
          publicKey: "peer_pub_key_b64",
        }),
      }),
      env
    );
    const { id: devReqId } = await reqRes.json();

    // Approve device with ECDH grant payload
    const appRes = await worker.fetch(
      new Request(
        `http://127.0.0.1:8787/privacy/device-requests/${devReqId}/approve`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ grant: "ecdh_wrapped_master_key_payload" }),
        }
      ),
      env
    );
    assert.equal(appRes.status, 200);

    // Poll approval status
    const pollRes = await worker.fetch(
      new Request(`http://127.0.0.1:8787/privacy/device-requests/${devReqId}`),
      env
    );
    const polled = await pollRes.json();
    assert.equal(polled.status, "approved");
    assert.equal(polled.grant, "ecdh_wrapped_master_key_payload");
  });

  it("7. Share Links (#sk= WebCrypto Viewer) and File Request Drop Portal", async () => {
    const env = createLocalEnv();

    // Upload a file first
    const upRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/files/upload?name=SecretDoc.pdf", {
        method: "POST",
        body: new TextEncoder().encode("EncryptedPieceBytes"),
      }),
      env
    );
    const file = await upRes.json();

    // Create share link
    const shRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/shares", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          fileID: file.id,
          fileKey: "wrapped_fk",
          fileNonce: "nonce_b64",
          encName: "e1:ciphername",
          shareKeyWrap: "sk_wrap",
        }),
      }),
      env
    );
    assert.equal(shRes.status, 200);
    const shareInfo = await shRes.json();

    // Fetch WebCrypto Share HTML
    const htmlRes = await worker.fetch(
      new Request(`http://127.0.0.1:8787/s/${shareInfo.token}`),
      env
    );
    assert.equal(htmlRes.status, 200);
    const html = await htmlRes.text();
    assert.ok(html.includes("helumi share v1"));

    // Download shared blob
    const dlRes = await worker.fetch(
      new Request(`http://127.0.0.1:8787/s/${shareInfo.token}/download`),
      env
    );
    assert.equal(await dlRes.text(), "EncryptedPieceBytes");

    // Create File Request for folder
    const freqRes = await worker.fetch(
      new Request("http://127.0.0.1:8787/file-requests", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          folderID: "dir_inbox",
          folderName: "Hộp thư Khách hàng",
        }),
      }),
      env
    );
    assert.equal(freqRes.status, 200);
    const freq = await freqRes.json();

    // Guest uploads file into File Request portal
    const dropUpRes = await worker.fetch(
      new Request(
        `http://127.0.0.1:8787/r/${freq.token}/upload?name=ClientContract.pdf&sealPublic=ephem_pub_p256`,
        {
          method: "POST",
          body: new TextEncoder().encode("SealedContractCiphertext"),
        }
      ),
      env
    );
    assert.equal(dropUpRes.status, 200);
    const dropped = await dropUpRes.json();
    assert.ok(dropped.fileID.startsWith("file_"));
  });
});

