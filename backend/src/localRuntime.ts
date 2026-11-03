import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

export class LocalD1PreparedStatement {
  private db: DatabaseSync;
  private sql: string;
  private params: any[];

  constructor(db: DatabaseSync, sql: string, params: any[] = []) {
    this.db = db;
    this.sql = sql;
    this.params = params;
  }

  bind(...values: any[]): LocalD1PreparedStatement {
    return new LocalD1PreparedStatement(this.db, this.sql, values);
  }

  async run(): Promise<{ success: boolean }> {
    const stmt = this.db.prepare(this.sql);
    stmt.run(...this.params);
    return { success: true };
  }

  async first<T = any>(): Promise<T | null> {
    const stmt = this.db.prepare(this.sql);
    const row = stmt.get(...this.params) as T | undefined;
    return row ?? null;
  }

  async all<T = any>(): Promise<{ results: T[] }> {
    const stmt = this.db.prepare(this.sql);
    const rows = stmt.all(...this.params) as T[];
    return { results: rows };
  }
}

export class LocalD1Database {
  private db: DatabaseSync;

  constructor(dbPath = ":memory:") {
    this.db = new DatabaseSync(dbPath);
    const schemaPath = join(__dirname, "..", "schema.sql");
    const schemaSql = readFileSync(schemaPath, "utf8");
    this.db.exec(schemaSql);
  }

  prepare(sql: string): LocalD1PreparedStatement {
    return new LocalD1PreparedStatement(this.db, sql);
  }

  exec(sql: string): void {
    this.db.exec(sql);
  }
}

export class LocalR2Bucket {
  private blobs = new Map<string, Uint8Array>();
  private multipartParts = new Map<string, Map<number, Uint8Array>>();

  async put(key: string, value: ArrayBuffer | Uint8Array | string): Promise<void> {
    if (typeof value === "string") {
      this.blobs.set(key, new TextEncoder().encode(value));
    } else if (value instanceof Uint8Array) {
      this.blobs.set(key, new Uint8Array(value));
    } else {
      this.blobs.set(key, new Uint8Array(value));
    }
  }

  async get(
    key: string,
    options?: { range?: { offset: number; length: number } }
  ): Promise<{ body: Uint8Array; size: number } | null> {
    const full = this.blobs.get(key);
    if (!full) return null;
    if (options?.range) {
      const start = Math.max(0, options.range.offset);
      const end = Math.min(full.byteLength, start + options.range.length);
      return {
        body: full.slice(start, end),
        size: full.byteLength,
      };
    }
    return {
      body: full,
      size: full.byteLength,
    };
  }

  async delete(key: string): Promise<void> {
    this.blobs.delete(key);
  }

  async createMultipartUpload(key: string): Promise<{ uploadId: string; key: string }> {
    const uploadId = `r2mpu_${crypto.randomUUID()}`;
    this.multipartParts.set(uploadId, new Map());
    return { uploadId, key };
  }

  resumeMultipartUpload(key: string, uploadId: string) {
    const bucket = this;
    return {
      async uploadPart(
        partNumber: number,
        value: ArrayBuffer | Uint8Array
      ): Promise<{ partNumber: number; etag: string }> {
        let partsMap = bucket.multipartParts.get(uploadId);
        if (!partsMap) {
          partsMap = new Map();
          bucket.multipartParts.set(uploadId, partsMap);
        }
        const bytes =
          value instanceof Uint8Array ? new Uint8Array(value) : new Uint8Array(value);
        partsMap.set(partNumber, bytes);
        return {
          partNumber,
          etag: `"etag-part-${partNumber}-${bytes.byteLength}"`,
        };
      },
      async complete(
        parts: Array<{ partNumber: number; etag: string }>
      ): Promise<void> {
        const partsMap = bucket.multipartParts.get(uploadId) ?? new Map();
        const sorted = [...parts].sort((a, b) => a.partNumber - b.partNumber);
        let total = 0;
        const chunks: Uint8Array[] = [];
        for (const p of sorted) {
          const chunk = partsMap.get(p.partNumber);
          if (chunk) {
            chunks.push(chunk);
            total += chunk.byteLength;
          }
        }
        const merged = new Uint8Array(total);
        let offset = 0;
        for (const c of chunks) {
          merged.set(c, offset);
          offset += c.byteLength;
        }
        bucket.blobs.set(key, merged);
        bucket.multipartParts.delete(uploadId);
      },
      async abort(): Promise<void> {
        bucket.multipartParts.delete(uploadId);
      },
    };
  }
}

export function createLocalEnv(dbPath = ":memory:"): {
  DB: any;
  BUCKET: any;
} {
  return {
    DB: new LocalD1Database(dbPath),
    BUCKET: new LocalR2Bucket(),
  };
}

