-- D1 SQLite Schema for XDrive / Orbit Cloud Backend

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    name TEXT,
    plan TEXT NOT NULL DEFAULT 'Pro 2 TB',
    storage_used INTEGER NOT NULL DEFAULT 0,
    storage_limit INTEGER NOT NULL DEFAULT 2199023255552,
    privacy_enabled INTEGER NOT NULL DEFAULT 0,
    key_check TEXT,
    drop_public TEXT,
    drop_private_wrap TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS files (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    parent_id TEXT,
    name TEXT NOT NULL,
    is_directory INTEGER NOT NULL DEFAULT 0,
    size INTEGER NOT NULL DEFAULT 0,
    mime_type TEXT,
    enc_name TEXT,
    name_hash TEXT,
    file_key TEXT,
    file_nonce TEXT,
    plain_size INTEGER,
    seal_public TEXT,
    deleted INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_files_user_parent ON files(user_id, parent_id, deleted);
CREATE INDEX IF NOT EXISTS idx_files_name_hash ON files(user_id, parent_id, name_hash);

CREATE TABLE IF NOT EXISTS changes (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    file_id TEXT NOT NULL,
    action TEXT NOT NULL, -- 'upsert' | 'delete'
    name TEXT,
    parent_id TEXT,
    is_directory INTEGER,
    size INTEGER,
    enc_name TEXT,
    file_key TEXT,
    file_nonce TEXT,
    plain_size INTEGER,
    seal_public TEXT,
    created_at TEXT,
    updated_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_changes_user_seq ON changes(user_id, seq);

CREATE TABLE IF NOT EXISTS shares (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    file_id TEXT NOT NULL,
    file_key TEXT,
    file_nonce TEXT,
    enc_name TEXT,
    share_key_wrap TEXT,
    downloads INTEGER NOT NULL DEFAULT 0,
    expires_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS device_requests (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_name TEXT NOT NULL,
    public_key TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending', -- 'pending' | 'approved' | 'rejected'
    grant_payload TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);

