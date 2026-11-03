-- D1 SQLite Schema for XDrive / Orbit Cloud Backend (Production Grade)

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    name TEXT,
    password_hash TEXT,
    plan TEXT NOT NULL DEFAULT 'Pro 2 TB',
    storage_used INTEGER NOT NULL DEFAULT 0,
    storage_limit INTEGER NOT NULL DEFAULT 2199023255552,
    privacy_enabled INTEGER NOT NULL DEFAULT 0,
    key_check TEXT,
    drop_public TEXT,
    drop_private_wrap TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    access_token TEXT PRIMARY KEY,
    refresh_token TEXT NOT NULL UNIQUE,
    user_id TEXT NOT NULL,
    device_name TEXT,
    expires_at INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_refresh ON sessions(refresh_token);

CREATE TABLE IF NOT EXISTS pkce_codes (
    code TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    code_challenge_method TEXT NOT NULL DEFAULT 'S256',
    expires_at INTEGER NOT NULL
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

CREATE INDEX IF NOT EXISTS idx_shares_user_file ON shares(user_id, file_id);

CREATE TABLE IF NOT EXISTS file_requests (
    token TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    folder_id TEXT NOT NULL,
    folder_name TEXT NOT NULL,
    drop_public TEXT,
    uploads_count INTEGER NOT NULL DEFAULT 0,
    expires_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS multipart_uploads (
    upload_id TEXT PRIMARY KEY,
    file_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    r2_key TEXT NOT NULL,
    r2_upload_id TEXT NOT NULL,
    name TEXT NOT NULL,
    parent_id TEXT,
    size INTEGER NOT NULL DEFAULT 0,
    enc_name TEXT,
    name_hash TEXT,
    file_key TEXT,
    file_nonce TEXT,
    plain_size INTEGER,
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

CREATE TABLE IF NOT EXISTS error_reports (
    id TEXT PRIMARY KEY,
    user_id TEXT,
    component TEXT NOT NULL,
    code TEXT NOT NULL,
    message TEXT NOT NULL,
    app_version TEXT,
    os_version TEXT,
    details_json TEXT,
    created_at TEXT NOT NULL
);
