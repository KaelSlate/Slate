//! Phase 3: Background Sync Engine
//!
//! Runs on a dedicated std::thread. Polls every 5 seconds.
//! Push phase: drain dirty queue → POST/PATCH/DELETE to Supabase PostgREST.
//! Pull phase: GET updated tasks since last sync → merge via LWW.
//! Crash-safe: queue persisted in SQLite before memory mutation.
//!
//! Fix 4: pull_remote now collects all tasks, runs a single
//!   `db.upsert_tasks_batch()` (one fsync) and acquires the TASK_STORE
//!   write-lock exactly once — eliminating N×fsync and N×lock-contention.

use crate::types::*;
use crate::local_db::LocalDb;

use std::sync::{Arc, RwLock, atomic::{AtomicBool, Ordering}};
use std::time::Duration;
use std::collections::HashMap;

/// Sync engine configuration
pub struct SyncConfig {
    pub supabase_url: String,
    pub supabase_key: String,
}

/// The background sync worker.
pub struct SyncEngine {
    running: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl SyncEngine {
    /// Spawn the background sync worker.
    ///
    /// # Arguments
    /// * `config` - Supabase connection config
    /// * `db` - Shared reference to the local SQLite database
    /// * `store` - Shared reference to the in-memory TaskStore (behind RwLock)
    pub fn spawn(
        config: SyncConfig,
        db: Arc<LocalDb>,
        store: Arc<RwLock<super::api::TaskStore>>,
    ) -> Self {
        let running = Arc::new(AtomicBool::new(true));
        let running_clone = running.clone();

        let handle = std::thread::Builder::new()
            .name("slate-sync".into())
            .spawn(move || {
                Self::worker_loop(running_clone, config, db, store);
            })
            // Fix 5: .expect() is acceptable here — this only runs at startup and
            // a thread-spawn failure is unrecoverable regardless. It is not in the
            // FFI hot path so no Dart-visible panic can occur.
            .expect("Failed to spawn sync thread");

        Self {
            running,
            handle: Some(handle),
        }
    }

    /// Stop the sync worker gracefully.
    pub fn stop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }

    /// Main worker loop. Runs until `running` is set to false.
    fn worker_loop(
        running: Arc<AtomicBool>,
        config: SyncConfig,
        db: Arc<LocalDb>,
        store: Arc<RwLock<super::api::TaskStore>>,
    ) {
        let mut backoff_ms: u64 = 5000; // Start at 5s
        const MAX_BACKOFF_MS: u64 = 60000; // Cap at 60s
        const NORMAL_INTERVAL_MS: u64 = 5000;

        // Initial sync on launch — pull remote state
        match Self::pull_remote(&config, &db, &store) {
            Ok(count) => {
                if count > 0 {
                    crate::dlog!("[sync] Initial pull: merged {} remote tasks", count);
                }
                backoff_ms = NORMAL_INTERVAL_MS;
            }
            Err(e) => {
                crate::dlog!("[sync] Initial pull failed (offline?): {}", e);
            }
        }

        while running.load(Ordering::Relaxed) {
            // Sleep in small increments so we can exit quickly
            let sleep_steps = backoff_ms / 100;
            for _ in 0..sleep_steps {
                if !running.load(Ordering::Relaxed) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }

            // --- Push phase: drain dirty queue ---
            let push_ok = match Self::push_dirty(&config, &db) {
                Ok(count) => {
                    if count > 0 {
                        crate::dlog!("[sync] Pushed {} operations", count);
                    }
                    true
                }
                Err(e) => {
                    crate::dlog!("[sync] Push failed: {}", e);
                    false
                }
            };

            // --- Pull phase: fetch remote updates ---
            let pull_ok = match Self::pull_remote(&config, &db, &store) {
                Ok(count) => {
                    if count > 0 {
                        crate::dlog!("[sync] Pulled {} updates", count);
                    }
                    true
                }
                Err(e) => {
                    crate::dlog!("[sync] Pull failed: {}", e);
                    false
                }
            };

            // --- Housekeeping ---
            db.purge_synced_deletes();

            // Adjust backoff
            if push_ok && pull_ok {
                backoff_ms = NORMAL_INTERVAL_MS;
            } else {
                backoff_ms = (backoff_ms * 2).min(MAX_BACKOFF_MS);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PUSH PHASE
    // ═══════════════════════════════════════════════════════════════════════

    /// Push dirty queue entries to Supabase. Returns number of ops pushed.
    fn push_dirty(config: &SyncConfig, db: &LocalDb) -> Result<usize, String> {
        let batch = db.dequeue_batch(50);
        if batch.is_empty() {
            return Ok(0);
        }

        let mut pushed = 0;

        for op in &batch {
            let result = match op.op {
                SyncOp::Create => Self::supabase_upsert(config, &op.payload),
                SyncOp::Update => Self::supabase_upsert(config, &op.payload),
                SyncOp::Delete => Self::supabase_delete(config, &op.task_id),
            };

            match result {
                Ok(_) => {
                    db.ack_op(op.queue_id);
                    pushed += 1;
                }
                Err(e) => {
                    // If it's a 409 conflict or client error, ack anyway to avoid stuck queue
                    if e.contains("409") || e.contains("404") {
                        db.ack_op(op.queue_id);
                        pushed += 1;
                    } else {
                        // Network error — stop processing this batch, retry later
                        return Err(e);
                    }
                }
            }
        }

        Ok(pushed)
    }

    /// Upsert a task to Supabase via PostgREST.
    fn supabase_upsert(config: &SyncConfig, payload_json: &str) -> Result<(), String> {
        // Parse the task JSON to build the Supabase-compatible payload
        let task: RustTask = serde_json::from_str(payload_json)
            .map_err(|e| format!("JSON parse error: {}", e))?;

        let created_dt = task.created_datetime();
        let updated_dt = chrono::Utc
            .timestamp_millis_opt(task.updated_at)
            .single()
            .unwrap_or_else(chrono::Utc::now);

        let start_dt = task.start_at.and_then(|ts| {
            chrono::Utc.timestamp_millis_opt(ts).single()
        });
        let end_dt = task.end_at.and_then(|ts| {
            chrono::Utc.timestamp_millis_opt(ts).single()
        });

        let body = serde_json::json!({
            "id": task.id,
            "title": task.title,
            "is_completed": task.is_completed,
            "created_at": created_dt.to_rfc3339(),
            "updated_at": updated_dt.to_rfc3339(),
            "start_at": start_dt.map(|dt| dt.to_rfc3339()),
            "end_at": end_dt.map(|dt| dt.to_rfc3339()),
            "user_id": task.user_id,
            "is_inbox": task.is_inbox,
        });

        let url = format!("{}/rest/v1/tasks", config.supabase_url);
        let resp = ureq::post(&url)
            .set("apikey", &config.supabase_key)
            .set("Authorization", &format!("Bearer {}", config.supabase_key))
            .set("Content-Type", "application/json; charset=utf-8")
            .set("Prefer", "resolution=merge-duplicates")
            .send_bytes(body.to_string().as_bytes());

        match resp {
            Ok(_) => Ok(()),
            Err(ureq::Error::Status(code, resp)) => {
                let mut reader = resp.into_reader();
                let mut bytes = Vec::new();
                std::io::Read::read_to_end(&mut reader, &mut bytes).ok();
                let body = String::from_utf8(bytes).unwrap_or_default();
                Err(format!("{}: {}", code, body))
            }
            Err(ureq::Error::Transport(t)) => {
                Err(format!("Network error: {}", t))
            }
        }
    }

    /// Delete a task from Supabase via PostgREST.
    fn supabase_delete(config: &SyncConfig, task_id: &str) -> Result<(), String> {
        // The id is interpolated into a PostgREST filter — only a strict UUID may
        // pass (blocks query/filter injection via a hostile id). "404" marker →
        // push_dirty acks the op so a poisoned entry can't wedge the queue forever.
        if uuid::Uuid::parse_str(task_id).is_err() {
            return Err(format!("404: refusing delete, non-UUID task id: {:?}", task_id));
        }
        let url = format!("{}/rest/v1/tasks?id=eq.{}", config.supabase_url, task_id);
        let resp = ureq::delete(&url)
            .set("apikey", &config.supabase_key)
            .set("Authorization", &format!("Bearer {}", config.supabase_key))
            .call();

        match resp {
            Ok(_) => Ok(()),
            Err(ureq::Error::Status(code, resp)) => {
                let mut reader = resp.into_reader();
                let mut bytes = Vec::new();
                std::io::Read::read_to_end(&mut reader, &mut bytes).ok();
                let body = String::from_utf8(bytes).unwrap_or_default();
                Err(format!("{}: {}", code, body))
            }
            Err(ureq::Error::Transport(t)) => {
                Err(format!("Network error: {}", t))
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // PULL PHASE (LWW MERGE) — Fix 4: single transaction + single lock
    // ═══════════════════════════════════════════════════════════════════════

    /// Pull remote updates from Supabase and merge via LWW.
    ///
    /// Fix 4 implementation:
    /// 1. Parse ALL remote tasks first (no I/O yet)
    /// 2. Filter via LWW against the current DB state
    /// 3. Call `db.upsert_tasks_batch()` — one single SQLite transaction → 1 fsync
    /// 4. Acquire the TASK_STORE write-lock ONCE and batch-apply all updates
    ///
    /// Previous implementation: N fsyncs + N lock acquisitions per pull cycle.
    /// New implementation:       1 fsync  + 1 lock acquisition per pull cycle.
    fn pull_remote(
        config: &SyncConfig,
        db: &LocalDb,
        store: &Arc<RwLock<super::api::TaskStore>>,
    ) -> Result<usize, String> {
        // Get last sync timestamp
        let last_sync = db.get_meta("last_sync_ts")
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);

        // Build query: get all tasks updated after last_sync
        let last_sync_dt = chrono::Utc
            .timestamp_millis_opt(last_sync)
            .single()
            .unwrap_or_else(chrono::Utc::now);

        let url = if last_sync == 0 {
            // Initial sync: get everything
            format!(
                "{}/rest/v1/tasks?select=id,title,is_completed,created_at,updated_at,start_at,end_at,user_id&order=updated_at.asc",
                config.supabase_url,
            )
        } else {
            let safe_date = last_sync_dt.to_rfc3339().replace("+", "%2B");
            format!(
                "{}/rest/v1/tasks?select=id,title,is_completed,created_at,updated_at,start_at,end_at,user_id&updated_at=gt.{}&order=updated_at.asc",
                config.supabase_url,
                safe_date,
            )
        };

        let resp = ureq::get(&url)
            .set("apikey", &config.supabase_key)
            .set("Authorization", &format!("Bearer {}", config.supabase_key))
            .call();

        let body = match resp {
            Ok(r) => {
                let mut reader = r.into_reader();
                let mut bytes = Vec::new();
                std::io::Read::read_to_end(&mut reader, &mut bytes).map_err(|e| format!("Read error: {}", e))?;
                String::from_utf8(bytes).map_err(|e| format!("UTF-8 error: {}", e))?
            },
            Err(ureq::Error::Status(code, r)) => {
                let mut reader = r.into_reader();
                let mut bytes = Vec::new();
                std::io::Read::read_to_end(&mut reader, &mut bytes).ok();
                let body = String::from_utf8(bytes).unwrap_or_default();
                return Err(format!("{}: {}", code, body));
            }
            Err(ureq::Error::Transport(t)) => {
                return Err(format!("Network error: {}", t));
            }
        };

        let remote_tasks: Vec<serde_json::Value> = serde_json::from_str(&body)
            .map_err(|e| format!("JSON parse error: {}", e))?;

        if remote_tasks.is_empty() {
            // Update last_sync even if no new data
            let now = chrono::Utc::now().timestamp_millis();
            db.set_meta("last_sync_ts", &now.to_string());
            return Ok(0);
        }

        // ── Phase 1: Parse + LWW filter ───────────────────────────────────
        // Collect all tasks that pass the LWW check into a single Vec.
        // This requires one DB read per task but no writes yet.
        let mut tasks_to_merge: Vec<RustTask> = Vec::new();
        let mut max_updated_at: i64 = last_sync;

        for remote_val in &remote_tasks {
            let remote_task = match Self::parse_remote_task(remote_val) {
                Some(t) => t,
                None => continue,
            };

            if remote_task.updated_at > max_updated_at {
                max_updated_at = remote_task.updated_at;
            }

            // LWW: compare with local version
            let local_task = db.get_task(&remote_task.id);
            let should_merge = match &local_task {
                None => true,                                                    // New from remote
                Some(local) => remote_task.updated_at > local.updated_at,       // Remote is newer
            };

            if should_merge {
                tasks_to_merge.push(remote_task);
            }
        }

        if tasks_to_merge.is_empty() {
            let now = chrono::Utc::now().timestamp_millis();
            db.set_meta("last_sync_ts", &now.to_string());
            return Ok(0);
        }

        let merged = tasks_to_merge.len();

        // ── Phase 2: Single batch write to SQLite (1 fsync) ──────────────
        db.upsert_tasks_batch(&tasks_to_merge);

        // ── Phase 3: Single write-lock for all in-memory updates ─────────
        {
            let mut guard = store.write().unwrap_or_else(|e| e.into_inner());
            for task in tasks_to_merge {
                guard.update(task);
            }
        } // Lock released here

        // Update last_sync timestamp
        let now = chrono::Utc::now().timestamp_millis();
        db.set_meta("last_sync_ts", &now.to_string());

        Ok(merged)
    }

    /// Parse a Supabase JSON row into a RustTask.
    fn parse_remote_task(val: &serde_json::Value) -> Option<RustTask> {
        let id = val.get("id")?.as_str()?.to_string();
        // Strict UUID gate on remote-supplied ids: anything else never enters the
        // local store or the sync queue (so it can't be echoed into later URLs).
        uuid::Uuid::parse_str(&id).ok()?;
        let title = val.get("title")?.as_str()?.to_string();
        let is_completed = val.get("is_completed")?.as_bool().unwrap_or(false);

        let created_at = Self::parse_timestamp(val.get("created_at")?)?;
        let updated_at = Self::parse_timestamp(val.get("updated_at")?)
            .unwrap_or(created_at);
        let start_at = val.get("start_at").and_then(Self::parse_timestamp);
        let end_at = val.get("end_at").and_then(Self::parse_timestamp);
        let user_id = val.get("user_id").and_then(|v| v.as_str().map(|s| s.to_string()));
        let is_inbox = val.get("is_inbox").and_then(|v| v.as_bool()).unwrap_or(false);

        // Phase 5: Parse new NLP fields from remote
        let start_time = val.get("start_time").and_then(|v| v.as_i64());
        let end_time = val.get("end_time").and_then(|v| v.as_i64());
        let priority = val.get("priority").and_then(|v| v.as_u64()).unwrap_or(0) as u8;
        let tags: Vec<String> = val.get("tags")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect())
            .unwrap_or_default();

        Some(RustTask {
            id,
            title,
            is_completed,
            created_at,
            updated_at,
            start_at,
            end_at,
            user_id,
            is_inbox,
            start_time,
            end_time,
            tags,
            priority,
        })
    }

    /// Parse an ISO 8601 timestamp or integer into milliseconds.
    fn parse_timestamp(val: &serde_json::Value) -> Option<i64> {
        if let Some(s) = val.as_str() {
            // ISO 8601 string
            chrono::DateTime::parse_from_rfc3339(s)
                .ok()
                .map(|dt| dt.timestamp_millis())
                .or_else(|| {
                    // Try without timezone
                    chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f")
                        .ok()
                        .map(|dt| dt.and_utc().timestamp_millis())
                })
        } else if let Some(n) = val.as_i64() {
            Some(n)
        } else {
            None
        }
    }
}

impl Drop for SyncEngine {
    fn drop(&mut self) {
        self.stop();
    }
}

use chrono::TimeZone;
