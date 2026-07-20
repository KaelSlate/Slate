//! Phase 3: Local SQLite Vault
//!
//! Persistent local storage for zero-latency offline operation.
//! All mutations are written to SQLite synchronously alongside the
//! in-memory TaskStore. The sync_queue table tracks dirty operations
//! that need to be pushed to Supabase.
//!
//! Fix 4: Added `upsert_tasks_batch` for single-transaction bulk upserts.
//! Fix 5: All `.unwrap()` calls replaced with safe error recovery paths.

use crate::types::*;
use rusqlite::{Connection, params, OptionalExtension};
use std::sync::Mutex;
use std::path::Path;

/// Why the vault refused to open — Dart shows a different recovery path for
/// each: a lost DPAPI key is not a locked file is not a corrupt schema.
#[derive(Debug)]
pub enum DbOpenError {
    /// The file itself didn't open (locked, path is a dir, permissions).
    Io(String),
    /// The file opened but the key doesn't unlock it (DPAPI key lost/changed).
    Key(String),
    /// Everything else (rekey/pragma/schema failures).
    Other(String),
}

impl DbOpenError {
    /// FFI return code for init_engine: -1 io, -2 key, -3 other.
    pub fn code(&self) -> i32 {
        match self {
            DbOpenError::Io(_) => -1,
            DbOpenError::Key(_) => -2,
            DbOpenError::Other(_) => -3,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            DbOpenError::Io(m) | DbOpenError::Key(m) | DbOpenError::Other(m) => m,
        }
    }
}

/// Thread-safe SQLite connection wrapper.
/// All access is serialized through the Mutex.
#[derive(Debug)]
pub struct LocalDb {
    conn: Mutex<Connection>,
}

impl LocalDb {
    /// Open (or create) the SQLite database at the given path.
    /// Creates tables if they don't exist.
    pub fn open(db_path: &str, db_key: &str) -> Result<Self, DbOpenError> {
        let is_memory = db_path == ":memory:";
        if !is_memory {
            // Ensure parent directory exists
            if let Some(parent) = Path::new(db_path).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        let open_raw = || -> Result<Connection, DbOpenError> {
            let c = if is_memory { Connection::open_in_memory() } else { Connection::open(db_path) };
            c.map_err(|e| DbOpenError::Io(format!("SQLite open failed: {}", e)))
        };

        // ── SQLCipher key ───────────────────────────────────────────────────────
        // db_key is a full-entropy 256-bit random value (see task_state _resolveDbKey),
        // so we key SQLCipher RAW (`x'<hex>'`) — no PBKDF2. KDF only exists to stretch
        // weak passwords; stretching an already-random key just burns ~100-250ms on
        // every cold start for zero security gain. MUST be the first op on the conn.
        //
        // Migration: a DB created by the previous build was encrypted with the key
        // passed as a *passphrase* (KDF-derived), so the raw key can't open it. We
        // probe the schema; on failure we back the file up and `rekey` it from the
        // legacy passphrase key to the raw key once — preserving every task.
        let conn = if db_key.is_empty() {
            open_raw()?
        } else {
            let c = open_raw()?;
            c.execute_batch(&format!("PRAGMA key = \"x'{}'\";\nPRAGMA cipher_page_size = 4096;", db_key))
                .map_err(|e| DbOpenError::Other(format!("SQLCipher raw key failed: {}", e)))?;
            let raw_ok = c
                .query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
                .is_ok();
            if raw_ok {
                c
            } else {
                drop(c);
                // Never risk the user's data: keep the original (incl. any uncheckpointed
                // WAL) alongside the migrated file before we rekey in place.
                if !is_memory {
                    let _ = std::fs::copy(db_path, format!("{}.pre-rawkey.bak", db_path));
                    let _ = std::fs::copy(format!("{}-wal", db_path), format!("{}-wal.pre-rawkey.bak", db_path));
                    let _ = std::fs::copy(format!("{}-shm", db_path), format!("{}-shm.pre-rawkey.bak", db_path));
                }
                let m = open_raw()?;
                m.execute_batch(&format!("PRAGMA key = '{}';\nPRAGMA cipher_page_size = 4096;", db_key))
                    .map_err(|e| DbOpenError::Other(format!("SQLCipher legacy key failed: {}", e)))?;
                m.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
                    .map_err(|e| DbOpenError::Key(format!("SQLCipher unlock failed (bad key / corrupt DB): {}", e)))?;
                m.execute_batch(&format!("PRAGMA rekey = \"x'{}'\";", db_key))
                    .map_err(|e| DbOpenError::Other(format!("SQLCipher rekey→raw failed: {}", e)))?;
                m
            }
        };

        // WAL mode for concurrent reads during sync
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            .map_err(|e| DbOpenError::Other(format!("SQLite PRAGMA failed: {}", e)))?;

        // Create tables
        let schema = conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                is_completed INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                is_deleted INTEGER NOT NULL DEFAULT 0,
                start_at INTEGER,
                end_at INTEGER,
                user_id TEXT,
                is_inbox INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS sync_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                op TEXT NOT NULL,
                task_id TEXT NOT NULL,
                payload TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS sync_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_tasks_updated ON tasks(updated_at);
            CREATE INDEX IF NOT EXISTS idx_tasks_deleted ON tasks(is_deleted);
            CREATE INDEX IF NOT EXISTS idx_sync_queue_created ON sync_queue(created_at);"
        );
        schema.map_err(|e| DbOpenError::Other(format!("SQLite schema creation failed: {}", e)))?;

        // Fix 5: .unwrap_or(0) instead of .unwrap()
        let user_version: i32 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap_or(0);
        if user_version < 1 {
            let _ = conn.execute("ALTER TABLE tasks ADD COLUMN start_at INTEGER", []);
            let _ = conn.execute("ALTER TABLE tasks ADD COLUMN end_at INTEGER", []);
            let _ = conn.execute("ALTER TABLE tasks ADD COLUMN user_id TEXT", []);
            let _ = conn.execute_batch("PRAGMA user_version = 1;");
        }
        // Phase 4: Inbox flag — safe additive migration for existing DBs
        if user_version < 2 {
            let _ = conn.execute(
                "ALTER TABLE tasks ADD COLUMN is_inbox INTEGER NOT NULL DEFAULT 0",
                [],
            );
            let _ = conn.execute_batch("PRAGMA user_version = 2;");
        }
        // Phase 5: Smart Day Input — start_time, end_time, tags_json, priority
        if user_version < 3 {
            let _ = conn.execute(
                "ALTER TABLE tasks ADD COLUMN start_time INTEGER",
                [],
            );
            let _ = conn.execute(
                "ALTER TABLE tasks ADD COLUMN end_time INTEGER",
                [],
            );
            let _ = conn.execute(
                "ALTER TABLE tasks ADD COLUMN tags_json TEXT NOT NULL DEFAULT '[]'",
                [],
            );
            let _ = conn.execute(
                "ALTER TABLE tasks ADD COLUMN priority INTEGER NOT NULL DEFAULT 0",
                [],
            );
            let _ = conn.execute_batch("PRAGMA user_version = 3;");
        }

        Ok(Self { conn: Mutex::new(conn) })
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TASK CRUD
    // ═══════════════════════════════════════════════════════════════════════

    pub fn load_all_tasks(&self) -> Vec<RustTask> {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        // Fix 5: prepare().unwrap() → match with empty Vec fallback
        let mut stmt = match conn.prepare(
            "SELECT id, title, is_completed, created_at, updated_at, start_at, end_at, user_id, is_inbox, \
             start_time, end_time, tags_json, priority \
             FROM tasks WHERE is_deleted = 0"
        ) {
            Ok(s) => s,
            Err(e) => {
                crate::dlog!("[db] load_all_tasks prepare failed: {}", e);
                return Vec::new();
            }
        };

        // Fix 5 + borrow fix: eagerly collect rows while stmt/conn are still alive.
        let rows_result = stmt.query_map([], |row| {
            let tags_json: String = row.get::<_, String>(11).unwrap_or_else(|_| "[]".to_string());
            let tags: Vec<String> = serde_json::from_str(&tags_json).unwrap_or_default();
            Ok(RustTask {
                id: row.get(0)?,
                title: row.get(1)?,
                is_completed: row.get::<_, i32>(2)? != 0,
                created_at: row.get(3)?,
                updated_at: row.get(4)?,
                start_at: row.get(5)?,
                end_at: row.get(6)?,
                user_id: row.get(7)?,
                is_inbox: row.get::<_, i32>(8).unwrap_or(0) != 0,
                start_time: row.get(9).ok().flatten(),
                end_time: row.get(10).ok().flatten(),
                tags,
                priority: row.get::<_, i32>(12).unwrap_or(0) as u8,
            })
        });
        match rows_result {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                crate::dlog!("[db] load_all_tasks query failed: {}", e);
                Vec::new()
            }
        }
    }

    pub fn upsert_task(&self, task: &RustTask) {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        let tags_json = serde_json::to_string(&task.tags).unwrap_or_else(|_| "[]".to_string());
        // Fix 5: .unwrap() → if let Err, log and continue
        if let Err(e) = conn.execute(
            "INSERT INTO tasks (id, title, is_completed, created_at, updated_at, is_deleted, start_at, end_at, user_id, is_inbox, start_time, end_time, tags_json, priority)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
             ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                is_completed = excluded.is_completed,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                start_at = excluded.start_at,
                end_at = excluded.end_at,
                user_id = excluded.user_id,
                is_inbox = excluded.is_inbox,
                start_time = excluded.start_time,
                end_time = excluded.end_time,
                tags_json = excluded.tags_json,
                priority = excluded.priority,
                is_deleted = 0",
            params![
                task.id,
                task.title,
                task.is_completed as i32,
                task.created_at,
                task.updated_at,
                task.start_at,
                task.end_at,
                task.user_id,
                task.is_inbox as i32,
                task.start_time,
                task.end_time,
                tags_json,
                task.priority as i32,
            ],
        ) {
            crate::dlog!("[db] upsert_task failed for {}: {}", task.id, e);
        }
    }

    /// Fix 4: Bulk upsert within a single SQLite transaction.
    /// Reduces N fsyncs → 1 fsync, vastly improving sync-pull performance.
    pub fn upsert_tasks_batch(&self, tasks: &[RustTask]) {
        if tasks.is_empty() {
            return;
        }
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        // BEGIN TRANSACTION — end-to-end atomicity with single fsync
        if let Err(e) = conn.execute_batch("BEGIN TRANSACTION;") {
            crate::dlog!("[db] batch BEGIN failed: {}", e);
            return;
        }
        for task in tasks {
            let tags_json = serde_json::to_string(&task.tags).unwrap_or_else(|_| "[]".to_string());
            if let Err(e) = conn.execute(
                "INSERT INTO tasks (id, title, is_completed, created_at, updated_at, is_deleted, start_at, end_at, user_id, is_inbox, start_time, end_time, tags_json, priority)
                 VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                 ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    is_completed = excluded.is_completed,
                    created_at = excluded.created_at,
                    updated_at = excluded.updated_at,
                    start_at = excluded.start_at,
                    end_at = excluded.end_at,
                    user_id = excluded.user_id,
                    is_inbox = excluded.is_inbox,
                    start_time = excluded.start_time,
                    end_time = excluded.end_time,
                    tags_json = excluded.tags_json,
                    priority = excluded.priority,
                    is_deleted = 0",
                params![
                    task.id,
                    task.title,
                    task.is_completed as i32,
                    task.created_at,
                    task.updated_at,
                    task.start_at,
                    task.end_at,
                    task.user_id,
                    task.is_inbox as i32,
                    task.start_time,
                    task.end_time,
                    tags_json,
                    task.priority as i32,
                ],
            ) {
                crate::dlog!("[db] batch upsert failed for {}: {}", task.id, e);
                // Rollback on any individual error and abort the batch
                let _ = conn.execute_batch("ROLLBACK;");
                return;
            }
        }
        if let Err(e) = conn.execute_batch("COMMIT;") {
            crate::dlog!("[db] batch COMMIT failed: {}", e);
            let _ = conn.execute_batch("ROLLBACK;");
        }
    }

    /// Soft-delete a task (mark is_deleted = 1).
    pub fn soft_delete_task(&self, task_id: &str, updated_at: i64) {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        // Fix 5: .unwrap() → log on error
        if let Err(e) = conn.execute(
            "UPDATE tasks SET is_deleted = 1, updated_at = ?1 WHERE id = ?2",
            params![updated_at, task_id],
        ) {
            crate::dlog!("[db] soft_delete_task failed for {}: {}", task_id, e);
        }
    }

    /// Hard-delete tasks that have been synced and are marked deleted.
    pub fn purge_synced_deletes(&self) {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        // Fix 5: .unwrap() → log on error
        if let Err(e) = conn.execute(
            "DELETE FROM tasks WHERE is_deleted = 1
             AND id NOT IN (SELECT task_id FROM sync_queue)",
            [],
        ) {
            crate::dlog!("[db] purge_synced_deletes failed: {}", e);
        }
    }

    pub fn get_task(&self, task_id: &str) -> Option<RustTask> {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        // Fix 5: .optional().unwrap() → .optional().unwrap_or(None)
        conn.query_row(
            "SELECT id, title, is_completed, created_at, updated_at, start_at, end_at, user_id, is_inbox, \
             start_time, end_time, tags_json, priority \
             FROM tasks WHERE id = ?1",
            params![task_id],
            |row| {
                let tags_json: String = row.get::<_, String>(11).unwrap_or_else(|_| "[]".to_string());
                let tags: Vec<String> = serde_json::from_str(&tags_json).unwrap_or_default();
                Ok(RustTask {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    is_completed: row.get::<_, i32>(2)? != 0,
                    created_at: row.get(3)?,
                    updated_at: row.get(4)?,
                    start_at: row.get(5)?,
                    end_at: row.get(6)?,
                    user_id: row.get(7)?,
                    is_inbox: row.get::<_, i32>(8).unwrap_or(0) != 0,
                    start_time: row.get(9).ok().flatten(),
                    end_time: row.get(10).ok().flatten(),
                    tags,
                    priority: row.get::<_, i32>(12).unwrap_or(0) as u8,
                })
            },
        ).optional().unwrap_or(None)
    }

    /// Graceful-shutdown checkpoint: fold the WAL back into the main DB file and
    /// truncate it. Called once from ffi_shutdown_engine when the window closes —
    /// keeps tasks.db self-contained and the -wal file from growing for weeks.
    pub fn checkpoint(&self) {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        if let Err(e) = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);") {
            crate::dlog!("[db] wal_checkpoint failed: {}", e);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SYNC QUEUE
    // ═══════════════════════════════════════════════════════════════════════

    /// Enqueue a sync operation.
    pub fn enqueue_op(&self, op: SyncOp, task_id: &str, payload: &str) {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        let now = chrono::Utc::now().timestamp_millis();
        // Fix 5: .unwrap() → log on error
        if let Err(e) = conn.execute(
            "INSERT INTO sync_queue (op, task_id, payload, created_at) VALUES (?1, ?2, ?3, ?4)",
            params![op.as_str(), task_id, payload, now],
        ) {
            crate::dlog!("[db] enqueue_op failed: {}", e);
        }
    }

    /// Dequeue a batch of sync operations (oldest first).
    pub fn dequeue_batch(&self, limit: usize) -> Vec<QueuedOp> {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        // Fix 5: prepare().unwrap() → match with empty Vec
        let mut stmt = match conn.prepare(
            "SELECT id, op, task_id, payload, created_at FROM sync_queue ORDER BY id ASC LIMIT ?1"
        ) {
            Ok(s) => s,
            Err(e) => {
                crate::dlog!("[db] dequeue_batch prepare failed: {}", e);
                return Vec::new();
            }
        };

        // Eagerly collect before dropping stmt/conn guard
        let rows_result = stmt.query_map(params![limit as i64], |row| {
            let op_str: String = row.get(1)?;
            Ok(QueuedOp {
                queue_id: row.get(0)?,
                op: SyncOp::from_str(&op_str).unwrap_or(SyncOp::Update),
                task_id: row.get(2)?,
                payload: row.get(3)?,
                created_at: row.get(4)?,
            })
        });
        match rows_result {
            Ok(rows) => rows.filter_map(|r| r.ok()).collect(),
            Err(e) => {
                crate::dlog!("[db] dequeue_batch query failed: {}", e);
                Vec::new()
            }
        }
    }

    /// Acknowledge (remove) a successfully synced operation.
    pub fn ack_op(&self, queue_id: i64) {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        // Fix 5: .unwrap() → log on error
        if let Err(e) = conn.execute(
            "DELETE FROM sync_queue WHERE id = ?1",
            params![queue_id],
        ) {
            crate::dlog!("[db] ack_op failed for queue_id {}: {}", queue_id, e);
        }
    }

    /// Get the count of pending sync operations.
    pub fn queue_len(&self) -> usize {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        conn.query_row("SELECT COUNT(*) FROM sync_queue", [], |row| row.get::<_, i64>(0))
            .unwrap_or(0) as usize
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SYNC METADATA
    // ═══════════════════════════════════════════════════════════════════════

    /// Get a sync metadata value.
    pub fn get_meta(&self, key: &str) -> Option<String> {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        conn.query_row(
            "SELECT value FROM sync_meta WHERE key = ?1",
            params![key],
            |row| row.get(0),
        ).optional().unwrap_or(None)
    }

    /// Set a sync metadata value.
    pub fn set_meta(&self, key: &str, value: &str) {
        let conn = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        // Fix 5: .unwrap() → log on error
        if let Err(e) = conn.execute(
            "INSERT INTO sync_meta (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        ) {
            crate::dlog!("[db] set_meta failed for key '{}': {}", key, e);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir() -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("slate_dbtest_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).expect("temp dir");
        d
    }

    #[test]
    fn wrong_key_classifies_as_key_error() {
        let dir = temp_dir();
        let path = dir.join("t.db");
        let path = path.to_str().expect("utf8 path");
        let key_a = "aa".repeat(32);
        let key_b = "bb".repeat(32);
        {
            let db = LocalDb::open(path, &key_a).expect("create with key A");
            db.set_meta("probe", "1");
        }
        let err = LocalDb::open(path, &key_b).expect_err("key B must not open it");
        assert!(matches!(err, DbOpenError::Key(_)), "got: {:?}", err);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn unopenable_path_classifies_as_io_error() {
        let dir = temp_dir(); // a DIRECTORY as the db path → io failure
        let err = LocalDb::open(dir.to_str().expect("utf8"), &"aa".repeat(32))
            .expect_err("a directory is not a database");
        assert!(matches!(err, DbOpenError::Io(_)), "got: {:?}", err);
        let _ = std::fs::remove_dir_all(dir);
    }
}
