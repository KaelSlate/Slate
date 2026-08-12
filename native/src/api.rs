//! SLATE Core Engine - Flutter Rust Bridge API
//! Phase 3: Zero-Latency Offline Engine — Rust-Owned Persistence + Sync
//!
//! Dart is a dumb renderer. All task state lives here:
//!   1. In-memory TaskStore (nanosecond reads)
//!   2. Local SQLite vault (crash-safe persistence)
//!   3. Background sync worker (Supabase push/pull with LWW)
//!
//! Fix 1: All spatial FFI functions now return #[repr(C)] structs — zero JSON.
//! Fix 2: SQLite I/O decoupled from FFI thread via DbWriteQueue + background worker.
//! Fix 5: Zero-Panic policy — all .unwrap() stripped from FFI-reachable paths.

use crate::types::*;
use crate::spatial;
use crate::ghost;
use crate::local_db::LocalDb;
use crate::sync_engine::{SyncEngine, SyncConfig};

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, LazyLock, RwLock, Mutex, Condvar};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// Maximum allowed string length from FFI callers (defense against buffer overflow / DoS).
const MAX_FFI_STRING_LEN: usize = 10_000;

/// Maximum stored task title length in bytes (anti self-DoS: keeps a single row
/// from ballooning the DB / sync payloads). Generous — ~1000+ words.
const MAX_TITLE_LEN: usize = 4_000;

/// Clamp a title to MAX_TITLE_LEN on a UTF-8 char boundary (same boundary-safe
/// technique as safe_cstr_to_string — a raw byte slice would panic → abort).
#[inline]
fn clamp_title(title: String) -> String {
    if title.len() <= MAX_TITLE_LEN {
        return title;
    }
    let cut = title.char_indices()
        .take_while(|(i, _)| *i <= MAX_TITLE_LEN)
        .last()
        .map(|(i, _)| i)
        .unwrap_or(0);
    title[..cut].to_string()
}

/// Safely read a C string from an FFI pointer with length validation.
/// Returns an empty string if the pointer is null or the string exceeds MAX_FFI_STRING_LEN.
#[inline]
unsafe fn safe_cstr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() { return String::new(); }
    let s = CStr::from_ptr(ptr).to_string_lossy();
    if s.len() > MAX_FFI_STRING_LEN {
        // Truncate on a UTF-8 char boundary — a raw byte slice `s[..N]` panics when
        // N lands inside a multibyte codepoint (Cyrillic = 2 bytes, emoji = 4), and
        // with panic = "abort" that instantly kills the whole process, no logs.
        let cut = s.char_indices()
            .take_while(|(i, _)| *i <= MAX_FFI_STRING_LEN)
            .last()
            .map(|(i, _)| i)
            .unwrap_or(0);
        s[..cut].to_string()
    } else {
        s.into_owned()
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TASK STORE — THE ADAMANTIUM CORE
// ═══════════════════════════════════════════════════════════════════════════════

/// High-performance in-memory task database.
///
/// - `tasks`: O(1) lookup by ID via HashMap
/// - `date_index`: O(log N) temporal queries via BTreeMap keyed by day-start-ms
///
/// All mutations reindex automatically. Reads are lock-free via RwLock::read().
pub struct TaskStore {
    /// Primary storage: task_id → RustTask
    pub tasks: HashMap<String, RustTask>,
    /// Temporal index: day_start_ms → Vec<task_id>
    /// Day-start is midnight UTC of the task's created_at date.
    pub date_index: BTreeMap<i64, Vec<String>>,
}

impl TaskStore {
    pub fn new() -> Self {
        Self {
            tasks: HashMap::new(),
            date_index: BTreeMap::new(),
        }
    }

    /// Calculate the day-start timestamp (midnight UTC) for a given ms timestamp.
    #[inline]
    pub fn day_start_ms(ts_ms: i64) -> i64 {
        use chrono::{Local, TimeZone};
        let secs = ts_ms / 1000;
        let nsecs = ((ts_ms % 1000) * 1_000_000) as u32;
        if let Some(dt) = Local.timestamp_opt(secs, nsecs).earliest() {
            // Fix 5: .unwrap() on and_hms_opt → .and_then chained safely
            if let Some(start) = dt.date_naive()
                .and_hms_opt(0, 0, 0)
                .and_then(|naive| naive.and_local_timezone(Local).earliest())
            {
                return start.timestamp_millis();
            }
        }
        // Fallback to UTC arithmetic if Local fails
        let day_secs = secs - (secs.rem_euclid(86400));
        day_secs * 1000
    }

    /// Insert a task into both the HashMap and the date index.
    pub fn insert(&mut self, task: RustTask) {
        let day = Self::day_start_ms(task.created_at);
        let id = task.id.clone();
        self.tasks.insert(id.clone(), task);
        self.date_index.entry(day).or_default().push(id);
    }

    /// Remove a task by ID from both structures. Returns the removed task and
    /// its position in the day's id list — undo restores it to that exact spot.
    pub fn remove(&mut self, task_id: &str) -> Option<(RustTask, usize)> {
        if let Some(task) = self.tasks.remove(task_id) {
            let day = Self::day_start_ms(task.created_at);
            let mut index = 0usize;
            if let Some(ids) = self.date_index.get_mut(&day) {
                index = ids.iter().position(|id| id == task_id).unwrap_or(0);
                ids.retain(|id| id != task_id);
                if ids.is_empty() {
                    self.date_index.remove(&day);
                }
            }
            Some((task, index))
        } else {
            None
        }
    }

    /// Insert with a KNOWN day-list position (clamped) — the undo restore path.
    pub fn insert_at(&mut self, task: RustTask, day_index: usize) {
        let day = Self::day_start_ms(task.created_at);
        let id = task.id.clone();
        self.tasks.insert(id.clone(), task);
        let ids = self.date_index.entry(day).or_default();
        let at = day_index.min(ids.len());
        ids.insert(at, id);
    }

    /// Update a task in-place. Reindexes if the day changed; an edit that
    /// KEEPS the day also keeps the task's position in the day list (the old
    /// remove+push silently moved every edited task to the end).
    pub fn update(&mut self, task: RustTask) {
        let id = task.id.clone();
        let new_day = Self::day_start_ms(task.created_at);
        match self.remove(&id) {
            Some((old, index)) if Self::day_start_ms(old.created_at) == new_day => {
                self.insert_at(task, index);
            }
            _ => self.insert(task),
        }
    }

    /// Get all tasks for a specific day (by day-start ms).
    pub fn tasks_for_day_start(&self, day_start: i64) -> Vec<RustTask> {
        match self.date_index.get(&day_start) {
            Some(ids) => ids
                .iter()
                .filter_map(|id| self.tasks.get(id))
                // Boundary enforcement — never return Inbox tasks
                // for temporal queries constructing the calendar grid.
                .filter(|t| !t.is_inbox)
                .cloned()
                .collect(),
            None => Vec::new(),
        }
    }

    /// Get all tasks as a Vec (for operations that need the full set).
    pub fn all_tasks(&self) -> Vec<RustTask> {
        self.tasks.values().cloned().collect()
    }

    /// Get total task count.
    pub fn len(&self) -> usize {
        self.tasks.len()
    }

    /// Get a mutable task by ID.
    pub fn get_mut(&mut self, id: &str) -> Option<&mut RustTask> {
        self.tasks.get_mut(id)
    }

    /// Clear all data and rebuild from a fresh Vec.
    pub fn rebuild(&mut self, tasks: Vec<RustTask>) {
        self.tasks.clear();
        self.date_index.clear();
        self.tasks.reserve(tasks.len());
        for task in tasks {
            self.insert(task);
        }
    }
}

/// Global task store — thread-safe via RwLock, lazily initialized.
static TASK_STORE: LazyLock<Arc<RwLock<TaskStore>>> = LazyLock::new(|| {
    Arc::new(RwLock::new(TaskStore::new()))
});

/// Global local database reference.
static LOCAL_DB: LazyLock<Mutex<Option<Arc<LocalDb>>>> = LazyLock::new(|| {
    Mutex::new(None)
});

/// Global sync engine reference.
static SYNC_ENGINE: LazyLock<Mutex<Option<SyncEngine>>> = LazyLock::new(|| {
    Mutex::new(None)
});

/// Whether the engine has been initialized.
static ENGINE_READY: LazyLock<std::sync::atomic::AtomicBool> = LazyLock::new(|| {
    std::sync::atomic::AtomicBool::new(false)
});

// ═══════════════════════════════════════════════════════════════════════════════
// FIX 2: ASYNC DB WRITE QUEUE
// Decouples SQLite I/O from the FFI thread entirely.
// FFI mutations update TASK_STORE in O(1), then fire-and-forget to this queue.
// The slate-db-writer thread drains the queue asynchronously, never blocking Dart.
// ═══════════════════════════════════════════════════════════════════════════════

/// A pending write operation for the background DB worker.
enum DbWriteOp {
    Upsert(RustTask),
    SoftDelete { task_id: String, updated_at: i64 },
    EnqueueSync { op: SyncOp, task_id: String, payload: String },
}

/// Async write queue: a Mutex-protected VecDeque + Condvar for wake-up.
struct DbWriteQueue {
    queue: Mutex<VecDeque<DbWriteOp>>,
    signal: Condvar,
}

impl DbWriteQueue {
    fn new() -> Self {
        Self {
            queue: Mutex::new(VecDeque::new()),
            signal: Condvar::new(),
        }
    }

    /// Push a write op and wake the worker thread immediately.
    fn push(&self, op: DbWriteOp) {
        // Fix 5: unwrap_or_else for poisoned lock recovery
        let mut q = self.queue.lock().unwrap_or_else(|e| e.into_inner());
        q.push_back(op);
        self.signal.notify_one();
    }

    /// Drain all queued ops (called by the background worker).
    fn drain(&self) -> Vec<DbWriteOp> {
        let mut q = self.queue.lock().unwrap_or_else(|e| e.into_inner());
        q.drain(..).collect()
    }

    /// Block until there is at least one op, or timeout after 1s (to allow shutdown checks).
    fn wait_for_work(&self) {
        let q = self.queue.lock().unwrap_or_else(|e| e.into_inner());
        if q.is_empty() {
            // Wait up to 1 second for a signal from push()
            let _ = self.signal.wait_timeout(q, std::time::Duration::from_secs(1));
        }
    }
}

static DB_WRITE_QUEUE: LazyLock<Arc<DbWriteQueue>> = LazyLock::new(|| {
    Arc::new(DbWriteQueue::new())
});

/// Spawn the background SQLite writer thread.
/// Called once during engine initialization.
fn spawn_db_writer(db: Arc<LocalDb>, queue: Arc<DbWriteQueue>) {
    std::thread::Builder::new()
        .name("slate-db-writer".into())
        .spawn(move || {
            loop {
                // Block until there is work, preventing busy-spin
                queue.wait_for_work();

                let ops = queue.drain();
                if ops.is_empty() {
                    continue;
                }

                for op in ops {
                    match op {
                        DbWriteOp::Upsert(task) => {
                            db.upsert_task(&task);
                        }
                        DbWriteOp::SoftDelete { task_id, updated_at } => {
                            db.soft_delete_task(&task_id, updated_at);
                        }
                        DbWriteOp::EnqueueSync { op, task_id, payload } => {
                            db.enqueue_op(op, &task_id, &payload);
                        }
                    }
                }
            }
        })
        .expect("Failed to spawn db-writer thread");
    // .expect() is acceptable here — startup failure at thread spawn is unrecoverable
    // regardless and does not reach the FFI boundary.
}

/// Fire-and-forget: queue a task upsert to SQLite asynchronously.
#[inline]
fn async_upsert(task: &RustTask) {
    DB_WRITE_QUEUE.push(DbWriteOp::Upsert(task.clone()));
}

/// Fire-and-forget: queue a soft-delete to SQLite asynchronously.
#[inline]
fn async_soft_delete(task_id: &str, updated_at: i64) {
    DB_WRITE_QUEUE.push(DbWriteOp::SoftDelete {
        task_id: task_id.to_string(),
        updated_at,
    });
}

/// Fire-and-forget: queue a sync-op enqueue to SQLite asynchronously.
#[inline]
fn async_enqueue_sync(op: SyncOp, task_id: &str, task: &RustTask) {
    let payload = serde_json::to_string(task).unwrap_or_default();
    DB_WRITE_QUEUE.push(DbWriteOp::EnqueueSync {
        op,
        task_id: task_id.to_string(),
        payload,
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// ENGINE INITIALIZATION (Phase 3)
// ═══════════════════════════════════════════════════════════════════════════════

/// Belt over the zero-panic law: with `panic = "abort"` the hook still runs
/// before the process dies, so the trace lands next to the Dart crash log
/// (slate_data/logs/rust_panic.txt). The panic still kills Flutter — this
/// only preserves the evidence. Capped by truncate-on-oversize.
fn install_panic_hook(db_path: &str) {
    let logs_dir = std::path::Path::new(db_path)
        .parent()
        .map(|p| p.join("logs"))
        .unwrap_or_else(|| std::path::PathBuf::from("logs"));
    std::panic::set_hook(Box::new(move |info| {
        use std::io::Write;
        let _ = std::fs::create_dir_all(&logs_dir);
        let path = logs_dir.join("rust_panic.txt");
        let oversize = std::fs::metadata(&path)
            .map(|m| m.len() > 256 * 1024)
            .unwrap_or(false);
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(!oversize)
            .write(true)
            .truncate(oversize)
            .open(&path);
        if let Ok(mut f) = file {
            let ts = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S");
            let _ = writeln!(f, "──── {} · slate_core v{}", ts, env!("CARGO_PKG_VERSION"));
            let _ = writeln!(f, "{}\n", info);
        }
    }));
}

/// Initialize the offline engine.
/// 1. Opens/creates SQLite database at db_path
/// 2. Loads all tasks from SQLite into in-memory TaskStore
/// 3. Spawns background db-writer + sync worker threads
///
/// Returns the number of tasks loaded from local DB, or a typed failure:
/// -1 the file didn't open (locked / io), -2 the key doesn't unlock it
/// (DPAPI key lost), -3 anything else. Dart shows a different recovery
/// path per code — a silent fallback here once masqueraded as data loss.
#[flutter_rust_bridge::frb(sync)]
pub fn init_engine(db_path: String, supabase_url: String, supabase_key: String, db_key: String) -> i32 {
    install_panic_hook(&db_path);

    // Open local DB with encryption key
    let db = match LocalDb::open(&db_path, &db_key) {
        Ok(db) => Arc::new(db),
        Err(e) => {
            crate::dlog!("[engine] SQLite open failed: {}", e.message());
            return e.code();
        }
    };

    // Load tasks from SQLite into memory
    let tasks = db.load_all_tasks();
    let count = tasks.len() as i32;

    {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        store.rebuild(tasks);
    }

    // Store the DB reference globally
    {
        let mut db_lock = LOCAL_DB.lock().unwrap_or_else(|e| e.into_inner());
        *db_lock = Some(db.clone());
    }

    // Fix 2: Spawn the background async DB writer thread
    spawn_db_writer(db.clone(), DB_WRITE_QUEUE.clone());

    // Spawn sync worker if Supabase config is provided
    if !supabase_url.is_empty() && !supabase_key.is_empty() {
        let config = SyncConfig {
            supabase_url,
            supabase_key,
        };
        let engine = SyncEngine::spawn(config, db, TASK_STORE.clone());
        let mut sync_lock = SYNC_ENGINE.lock().unwrap_or_else(|e| e.into_inner());
        *sync_lock = Some(engine);
    }

    ENGINE_READY.store(true, std::sync::atomic::Ordering::Relaxed);
    crate::dlog!("[engine] Initialized with {} tasks from local DB", count);
    count
}

/// Legacy: Bootstrap the Rust task store from Dart (Phase 2 compat).
#[flutter_rust_bridge::frb(sync)]
pub fn init_task_store(tasks: Vec<RustTask>) {
    let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
    store.rebuild(tasks);
}

/// Get all tasks from the store (for initial UI hydration).
#[flutter_rust_bridge::frb(sync)]
pub fn get_all_tasks() -> Vec<RustTask> {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    store.all_tasks()
}

// ═══════════════════════════════════════════════════════════════════════════════
// TASK MUTATIONS (Fix 2: Memory + Async SQLite + Sync Queue)
// ═══════════════════════════════════════════════════════════════════════════════

/// Helper: get DB reference (None if engine not initialized).
fn get_db() -> Option<Arc<LocalDb>> {
    LOCAL_DB.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Create a new task, insert it into the store, persist to SQLite asynchronously.
#[flutter_rust_bridge::frb(sync)]
pub fn create_task(title: String, now_ts: i64) -> RustTask {
    let now = chrono::Utc::now().timestamp_millis();
    let id = uuid::Uuid::new_v4().to_string();

    let task = RustTask {
        id,
        title: clamp_title(title),
        is_completed: false,
        created_at: now_ts,
        updated_at: now,
        start_at: None,
        end_at: None,
        user_id: None,
        is_inbox: false,
        start_time: None,
        end_time: None,
        tags: Vec::new(),
        priority: 0,
    };

    // 1. Insert into memory store — O(1), returns immediately to Dart
    {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        store.insert(task.clone());
    }

    // 2. Fix 2: Offload SQLite write + sync enqueue to background worker
    async_upsert(&task);
    async_enqueue_sync(SyncOp::Create, &task.id, &task);

    task
}

/// Create a new Inbox task (is_inbox = true). Persists to SQLite + syncs asynchronously.
#[flutter_rust_bridge::frb(sync)]
pub fn create_inbox_task(title: String, now_ts: i64) -> RustTask {
    let now = chrono::Utc::now().timestamp_millis();
    let id = uuid::Uuid::new_v4().to_string();

    let task = RustTask {
        id,
        title: clamp_title(title),
        is_completed: false,
        created_at: now_ts,
        updated_at: now,
        start_at: None,
        end_at: None,
        user_id: None,
        is_inbox: true,
        start_time: None,
        end_time: None,
        tags: Vec::new(),
        priority: 0,
    };

    {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        store.insert(task.clone());
    }

    // Fix 2: async I/O
    async_upsert(&task);
    async_enqueue_sync(SyncOp::Create, &task.id, &task);

    task
}

/// Add a single task to the store (used by init flow or external import).
#[flutter_rust_bridge::frb(sync)]
pub fn add_task(task: RustTask) {
    {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        store.insert(task.clone());
    }

    // Fix 2: async upsert
    async_upsert(&task);
}

/// Toggle task completion status — mutates store, persists asynchronously.
#[flutter_rust_bridge::frb(sync)]
pub fn toggle_task(task_id: String) -> Option<RustTask> {
    let now = chrono::Utc::now().timestamp_millis();

    let updated_task = {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        if let Some(task) = store.get_mut(&task_id) {
            task.is_completed = !task.is_completed;
            task.updated_at = now;
            Some(task.clone())
        } else {
            None
        }
    };

    // Fix 2: async I/O — SQLite write is completely off the FFI thread
    if let Some(ref task) = updated_task {
        async_upsert(task);
        async_enqueue_sync(SyncOp::Update, &task.id, task);
    }

    updated_task
}

/// Update an existing task in the store (handles reindexing). Async persistence.
#[flutter_rust_bridge::frb(sync)]
pub fn update_task(task: RustTask) {
    {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        store.update(task.clone());
    }

    // Fix 2: async I/O
    async_upsert(&task);
    async_enqueue_sync(SyncOp::Update, &task.id, &task);
}

/// Remove a task from the store by ID. Soft-deletes in SQLite asynchronously.
/// Returns the task's position in its day list (-1 if not found) — the undo
/// snapshot keeps it so restore lands on the same spot.
#[flutter_rust_bridge::frb(sync)]
pub fn remove_task(task_id: String) -> i32 {
    let now = chrono::Utc::now().timestamp_millis();

    let index = {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        store.remove(&task_id).map(|(_, i)| i as i32).unwrap_or(-1)
    };

    // Fix 2: async I/O
    async_soft_delete(&task_id, now);
    DB_WRITE_QUEUE.push(DbWriteOp::EnqueueSync {
        op: SyncOp::Delete,
        task_id: task_id.clone(),
        payload: "{}".to_string(),
    });
    index
}

/// Rebuild a deleted task in ONE call — full state (done, inbox, tags,
/// priority, times, ORIGINAL created_at) and its original day-list position.
/// New id; persists exactly like a create.
#[flutter_rust_bridge::frb(sync)]
pub fn restore_task(
    title: String,
    created_at: i64,
    start_time: Option<i64>,
    end_time: Option<i64>,
    priority: u8,
    tags: Vec<String>,
    is_inbox: bool,
    is_completed: bool,
    day_index: usize,
) -> RustTask {
    let now = chrono::Utc::now().timestamp_millis();
    let task = RustTask {
        id: uuid::Uuid::new_v4().to_string(),
        title: clamp_title(title),
        is_completed,
        created_at,
        updated_at: now,
        start_at: None,
        end_at: None,
        user_id: None,
        is_inbox,
        start_time,
        end_time,
        tags,
        priority: priority.min(2),
    };

    {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        store.insert_at(task.clone(), day_index);
    }

    async_upsert(&task);
    async_enqueue_sync(SyncOp::Create, &task.id, &task);
    task
}

/// Get the total number of tasks in the store.
#[flutter_rust_bridge::frb(sync)]
pub fn task_count() -> u32 {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    store.len() as u32
}

/// Get the number of pending sync operations.
#[flutter_rust_bridge::frb(sync)]
pub fn sync_queue_length() -> u32 {
    get_db().map(|db| db.queue_len() as u32).unwrap_or(0)
}

// ═══════════════════════════════════════════════════════════════════════════════
// SPATIAL CALCULATIONS (exported to Dart via flutter_rust_bridge)
// ═══════════════════════════════════════════════════════════════════════════════

#[flutter_rust_bridge::frb(sync)]
pub fn calculate_flow_frame(
    selected_date_ts: i64,
    viewport_width: f64,
    scroll_offset: f64,
) -> SpatialFrame {
    spatial::calculate_flow_frame(selected_date_ts, viewport_width, scroll_offset)
}

#[flutter_rust_bridge::frb(sync)]
pub fn generate_hour_slots(
    selected_date_ts: i64,
    viewport_width: f64,
    scroll_offset: f64,
    task_counts: Vec<u32>,
) -> Vec<HourSlot> {
    spatial::generate_hour_slots(selected_date_ts, viewport_width, scroll_offset, task_counts)
}

#[flutter_rust_bridge::frb(sync)]
pub fn generate_week_cells(current_date_ts: i64) -> Vec<DayCell> {
    spatial::generate_week_cells(current_date_ts)
}

#[flutter_rust_bridge::frb(sync)]
pub fn generate_month_cells(year: i32, month: u32) -> Vec<Option<DayCell>> {
    spatial::generate_month_cells(year, month)
}

#[flutter_rust_bridge::frb(sync)]
pub fn calculate_magnetic_snap(
    scroll_offset: f64,
    velocity: f64,
    day_boundary_offset: f64,
) -> f64 {
    spatial::calculate_magnetic_snap(scroll_offset, velocity, day_boundary_offset)
}

#[flutter_rust_bridge::frb(sync)]
pub fn calculate_zoom_scale(level: StaircaseLevel, progress: f64) -> f64 {
    spatial::calculate_zoom_scale(level, progress)
}

// ═══════════════════════════════════════════════════════════════════════════════
// GHOST TASK PROCESSING — READS FROM STORE
// ═══════════════════════════════════════════════════════════════════════════════

pub fn extract_ghost_tasks(now_ts: i64) -> Vec<GhostTask> {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    let all = store.all_tasks();
    let ghosts = ghost::extract_ghost_tasks(all, now_ts);
    ghost::sort_ghosts_by_age(ghosts)
}

#[flutter_rust_bridge::frb(sync)]
pub fn tasks_for_date(date_ts: i64) -> Vec<RustTask> {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    let day_start = TaskStore::day_start_ms(date_ts);
    store.tasks_for_day_start(day_start)
}

#[flutter_rust_bridge::frb(sync)]
pub fn tasks_for_hour(date_ts: i64, hour: u8) -> Vec<RustTask> {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    let day_start = TaskStore::day_start_ms(date_ts);
    let day_tasks = store.tasks_for_day_start(day_start);
    ghost::tasks_for_hour(&day_tasks, date_ts, hour)
}

#[flutter_rust_bridge::frb(sync)]
pub fn task_counts_by_hour(date_ts: i64) -> Vec<u32> {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    let day_start = TaskStore::day_start_ms(date_ts);
    let day_tasks = store.tasks_for_day_start(day_start);
    ghost::task_counts_by_hour(&day_tasks, date_ts)
}

#[flutter_rust_bridge::frb(sync)]
pub fn batch_update_week_counts(week_start_ts: i64) -> Vec<TaskCounts> {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    let week_start_day = TaskStore::day_start_ms(week_start_ts);
    let week_end_day = week_start_day + (7 * 86400 * 1000);

    let mut week_tasks: Vec<RustTask> = Vec::new();
    for (_day, ids) in store.date_index.range(week_start_day..week_end_day) {
        for id in ids {
            if let Some(task) = store.tasks.get(id) {
                if !task.is_inbox {
                    week_tasks.push(task.clone());
                }
            }
        }
    }

    ghost::batch_update_week_counts(&week_tasks, week_start_ts)
        .into_iter()
        .map(|(total, completed)| TaskCounts { total, completed })
        .collect()
}

#[flutter_rust_bridge::frb(sync)]
pub fn calculate_year_heatmap(year: i32) -> Vec<u32> {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    let all = store.all_tasks();
    spatial::calculate_year_heatmap(&all, year).to_vec()
}

// ═══════════════════════════════════════════════════════════════════════════════
// NAVIGATION STATE
// ═══════════════════════════════════════════════════════════════════════════════

static NAV_STATE: LazyLock<RwLock<NavigationState>> = LazyLock::new(|| {
    RwLock::new(NavigationState {
        level: StaircaseLevel::Tactics,
        tactics_mode: TacticsMode::Week,
        selected_date_ts: 0,
    })
});

#[derive(Debug, Clone)]
pub struct TaskCounts {
    pub total: u32,
    pub completed: u32,
}

#[derive(Debug, Clone)]
pub struct NavigationState {
    pub level: StaircaseLevel,
    pub tactics_mode: TacticsMode,
    pub selected_date_ts: i64,
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_navigation_state() -> NavigationState {
    NAV_STATE.read().unwrap_or_else(|e| e.into_inner()).clone()
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_navigation_level(level: StaircaseLevel) {
    NAV_STATE.write().unwrap_or_else(|e| e.into_inner()).level = level;
}

#[flutter_rust_bridge::frb(sync)]
pub fn enter_day(date_ts: i64) {
    let mut state = NAV_STATE.write().unwrap_or_else(|e| e.into_inner());
    state.selected_date_ts = date_ts;
    state.level = StaircaseLevel::Planning;
}

#[flutter_rust_bridge::frb(sync)]
pub fn toggle_tactics_mode() {
    let mut state = NAV_STATE.write().unwrap_or_else(|e| e.into_inner());
    state.tactics_mode = match state.tactics_mode {
        TacticsMode::Week => TacticsMode::Month,
        TacticsMode::Month => TacticsMode::Week,
    };
}

#[flutter_rust_bridge::frb(sync)]
pub fn zoom_in() -> bool {
    let mut state = NAV_STATE.write().unwrap_or_else(|e| e.into_inner());
    match state.level {
        StaircaseLevel::Strategy => { state.level = StaircaseLevel::Tactics; true }
        StaircaseLevel::Tactics => false,
        StaircaseLevel::Planning => { state.level = StaircaseLevel::Flow; true }
        StaircaseLevel::Flow => false,
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn zoom_out() -> bool {
    let mut state = NAV_STATE.write().unwrap_or_else(|e| e.into_inner());
    match state.level {
        StaircaseLevel::Strategy => false,
        StaircaseLevel::Tactics => { state.level = StaircaseLevel::Strategy; true }
        StaircaseLevel::Planning => { state.level = StaircaseLevel::Tactics; true }
        StaircaseLevel::Flow => { state.level = StaircaseLevel::Planning; true }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SPRING PHYSICS
// ═══════════════════════════════════════════════════════════════════════════════

#[flutter_rust_bridge::frb(sync)]
pub fn calculate_spring_snap(
    scroll_offset: f64,
    velocity: f64,
    day_boundary_offset: f64,
    dt: f64,
) -> (f64, f64) {
    let distance = scroll_offset - day_boundary_offset;
    let snap_threshold = 120.0;
    let spring_constant = 0.08;
    let damping = 0.92;

    if distance.abs() < snap_threshold && velocity.abs() < 150.0 {
        let spring_force = -spring_constant * distance;
        let new_velocity = (velocity + spring_force * dt * 60.0) * damping;
        let new_offset = scroll_offset + new_velocity * dt;
        (new_offset, new_velocity)
    } else {
        (scroll_offset, velocity)
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn calculate_day_transition_opacity(scroll_offset: f64, day_boundary: f64) -> f64 {
    let transition_zone = 200.0;
    let distance_past_boundary = scroll_offset - day_boundary;

    if distance_past_boundary < 0.0 {
        0.0
    } else if distance_past_boundary > transition_zone {
        1.0
    } else {
        distance_past_boundary / transition_zone
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// HEALTHCHECK
// ═══════════════════════════════════════════════════════════════════════════════

#[flutter_rust_bridge::frb(sync)]
pub fn health_check() -> String {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    let queue_len = get_db().map(|db| db.queue_len()).unwrap_or(0);
    format!(
        "SLATE Core Engine v4.1.0 - Phase 4 [{} tasks, {} pending sync, async-db=on, zero-copy=on]",
        store.len(),
        queue_len,
    )
}

// ═══════════════════════════════════════════════════════════════════════════════
// C-ABI EXPORTS FOR DIRECT FFI (dart:ffi DynamicLibrary)
// ═══════════════════════════════════════════════════════════════════════════════



// ─────────────────────────────────────────────────────────────────────────────
// Fix 1: TASK C STRUCTS (already existed)
// ─────────────────────────────────────────────────────────────────────────────

#[repr(C)]
pub struct CTask {
    pub id: *mut c_char,
    pub title: *mut c_char,
    pub is_completed: bool,
    pub is_inbox: bool,
    pub created_at: i64,
    pub updated_at: i64,
    pub start_at: i64,
    pub end_at: i64,
    /// Intra-day start time (minutes since midnight), -1 if unallocated.
    pub start_time: i64,
    /// Intra-day end time (minutes since midnight), -1 if unallocated.
    pub end_time: i64,
    /// Priority level (0=Normal, 1=Important, 2=Very Important).
    pub priority: u8,
    /// Zero-copy tag array — each element is a NUL-terminated C string owned by Rust.
    /// Caller must free via ffi_free_task / ffi_free_task_list (Caller-Frees protocol).
    pub tags: *mut *mut c_char,
    pub tag_count: usize,
}

impl CTask {
    pub fn from_rust_task(t: &RustTask) -> Self {
        // Allocate each tag as an independent CString and collect raw pointers.
        // Zero JSON — raw heap strings transferred directly across the ABI boundary.
        let tag_ptrs: Vec<*mut c_char> = t.tags.iter()
            .map(|s| CString::new(s.as_str()).unwrap_or_default().into_raw())
            .collect();
        let tag_count = tag_ptrs.len();
        // Box the pointer array so Rust owns the backing allocation.
        // We immediately forget the Box to transfer ownership to the caller.
        let tags_ptr = if tag_count > 0 {
            let mut boxed: Box<[*mut c_char]> = tag_ptrs.into_boxed_slice();
            let ptr = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            ptr
        } else {
            std::ptr::null_mut()
        };

        Self {
            id:    CString::new(t.id.clone()).unwrap_or_default().into_raw(),
            title: CString::new(t.title.clone()).unwrap_or_default().into_raw(),
            is_completed: t.is_completed,
            is_inbox: t.is_inbox,
            created_at: t.created_at,
            updated_at: t.updated_at,
            start_at: t.start_at.unwrap_or(0),
            end_at: t.end_at.unwrap_or(0),
            start_time: t.start_time.unwrap_or(-1),
            end_time: t.end_time.unwrap_or(-1),
            priority: t.priority,
            tags: tags_ptr,
            tag_count,
        }
    }
}

/// Helper: free the tag array allocated by CTask::from_rust_task.
/// Walks each *mut c_char pointer, drops the CString, then frees the outer array.
/// This is an internal helper — always called from ffi_free_task / ffi_free_task_list.
///
/// SAFETY: `tags` must have been allocated by `CTask::from_rust_task` using `Box::into_raw`.
#[inline]
unsafe fn free_ctask_tags(tags: *mut *mut c_char, tag_count: usize) {
    if tags.is_null() || tag_count == 0 { return; }
    // Reconstruct the Box<[*mut c_char]> to reclaim the array allocation.
    let tag_slice = std::slice::from_raw_parts_mut(tags, tag_count);
    for tag_ptr in tag_slice.iter() {
        if !(*tag_ptr).is_null() {
            drop(CString::from_raw(*tag_ptr));
        }
    }
    // Free the array itself by reconstructing the Box.
    drop(Box::from_raw(std::slice::from_raw_parts_mut(tags, tag_count)));
}

#[repr(C)]
pub struct CTaskList {
    pub data: *mut CTask,
    pub len: usize,
    pub capacity: usize,
}

impl CTaskList {
    pub fn from_vec(tasks: Vec<RustTask>) -> Self {
        let mut c_tasks = Vec::with_capacity(tasks.len());
        for t in tasks {
            c_tasks.push(CTask::from_rust_task(&t));
        }
        let mut c_tasks = std::mem::ManuallyDrop::new(c_tasks);
        Self {
            data: c_tasks.as_mut_ptr(),
            len: c_tasks.len(),
            capacity: c_tasks.capacity(),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fix 1: SPATIAL C STRUCTS — replaces all JSON serialization
// ─────────────────────────────────────────────────────────────────────────────

/// #[repr(C)] DayCell for zero-copy FFI transfer.
/// Dart reads fields directly via pointer arithmetic — no JSON, no heap alloc.
#[repr(C)]
pub struct CDayCell {
    pub date_timestamp: i64,
    pub day_of_week: u8,
    pub day_of_month: u8,
    pub is_today: bool,
    pub task_count: u32,
    pub completed_count: u32,
    /// Padding to reach 8-byte alignment boundary (avoids ABI surprises).
    _pad: [u8; 2],
}

impl CDayCell {
    pub fn from_rust(c: &DayCell) -> Self {
        Self {
            date_timestamp: c.date_timestamp,
            day_of_week: c.day_of_week,
            day_of_month: c.day_of_month,
            is_today: c.is_today,
            task_count: c.task_count,
            completed_count: c.completed_count,
            _pad: [0; 2],
        }
    }
}

/// List of CDayCells. Caller must free with `ffi_free_day_cell_list`.
#[repr(C)]
pub struct CDayCellList {
    pub data: *mut CDayCell,
    pub len: usize,
    pub capacity: usize,
}

impl CDayCellList {
    fn from_vec(cells: Vec<DayCell>) -> Self {
        let mut c_cells: Vec<CDayCell> = cells.iter().map(CDayCell::from_rust).collect();
        let mut c_cells = std::mem::ManuallyDrop::new(c_cells);
        Self {
            data: c_cells.as_mut_ptr(),
            len: c_cells.len(),
            capacity: c_cells.capacity(),
        }
    }
}

/// Nullable Day Cell list (for month grid with padding slots).
/// `is_valid` = 1 if this slot contains a real day, 0 = padding.
#[repr(C)]
pub struct COptDayCell {
    pub cell: CDayCell,
    pub is_valid: u8,
    _pad: [u8; 7],
}

/// List of COptDayCell (42 slots for month grid). Caller frees with `ffi_free_month_cell_list`.
#[repr(C)]
pub struct CMonthCellList {
    pub data: *mut COptDayCell,
    pub len: usize,
    pub capacity: usize,
}

/// #[repr(C)] HourSlot for zero-copy FFI transfer.
#[repr(C)]
pub struct CHourSlot {
    pub hour: u8,
    pub is_current: bool,
    _pad: [u8; 6],
    pub x_offset: f64,
    pub task_count: u32,
    _pad2: u32,
}

impl CHourSlot {
    pub fn from_rust(s: &HourSlot) -> Self {
        Self {
            hour: s.hour,
            is_current: s.is_current,
            _pad: [0; 6],
            x_offset: s.x_offset,
            task_count: s.task_count,
            _pad2: 0,
        }
    }
}

/// List of CHourSlots. Caller frees with `ffi_free_hour_slot_list`.
#[repr(C)]
pub struct CHourSlotList {
    pub data: *mut CHourSlot,
    pub len: usize,
    pub capacity: usize,
}

impl CHourSlotList {
    fn from_vec(slots: Vec<HourSlot>) -> Self {
        let mut c_slots: Vec<CHourSlot> = slots.iter().map(CHourSlot::from_rust).collect();
        let mut c_slots = std::mem::ManuallyDrop::new(c_slots);
        Self {
            data: c_slots.as_mut_ptr(),
            len: c_slots.len(),
            capacity: c_slots.capacity(),
        }
    }
}

/// #[repr(C)] SpatialFrame for zero-copy FFI transfer.
#[repr(C)]
pub struct CSpatialFrame {
    pub visible_start: i64,
    pub visible_end: i64,
    pub hour_width: f64,
    pub current_offset: f64,
    pub total_width: f64,
}

impl CSpatialFrame {
    fn from_rust(f: &SpatialFrame) -> Self {
        Self {
            visible_start: f.visible_start,
            visible_end: f.visible_end,
            hour_width: f.hour_width,
            current_offset: f.current_offset,
            total_width: f.total_width,
        }
    }
}

/// u32 array list for heatmap / hour-counts data.
/// Caller frees with `ffi_free_u32_list`.
#[repr(C)]
pub struct CU32List {
    pub data: *mut u32,
    pub len: usize,
    pub capacity: usize,
}

impl CU32List {
    fn from_vec(v: Vec<u32>) -> Self {
        let mut v = std::mem::ManuallyDrop::new(v);
        Self {
            data: v.as_mut_ptr(),
            len: v.len(),
            capacity: v.capacity(),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// C-ABI FREE FUNCTIONS
// ─────────────────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ffi_free_task(ptr: *mut CTask) {
    if ptr.is_null() { return; }
    unsafe {
        let t = Box::from_raw(ptr);
        if !t.id.is_null()    { drop(CString::from_raw(t.id)); }
        if !t.title.is_null() { drop(CString::from_raw(t.title)); }
        // Zero-copy tag array: free each string, then the array itself.
        free_ctask_tags(t.tags, t.tag_count);
    }
}

#[no_mangle]
pub extern "C" fn ffi_free_task_list(list: CTaskList) {
    if list.data.is_null() { return; }
    unsafe {
        // Reconstruct the Vec to reclaim backing storage.
        let vec = Vec::from_raw_parts(list.data, list.len, list.capacity);
        for t in vec {
            if !t.id.is_null()    { drop(CString::from_raw(t.id)); }
            if !t.title.is_null() { drop(CString::from_raw(t.title)); }
            free_ctask_tags(t.tags, t.tag_count);
        }
    }
}

/// Fix 1: Free a CDayCellList returned by ffi_generate_week_cells.
#[no_mangle]
pub extern "C" fn ffi_free_day_cell_list(list: CDayCellList) {
    if list.data.is_null() { return; }
    unsafe {
        let _ = Vec::from_raw_parts(list.data, list.len, list.capacity);
        // No sub-allocations — CDayCell is POD, drop reconstructs and frees the backing array
    }
}

/// Fix 1: Free a CMonthCellList returned by ffi_generate_month_cells.
#[no_mangle]
pub extern "C" fn ffi_free_month_cell_list(list: CMonthCellList) {
    if list.data.is_null() { return; }
    unsafe {
        let _ = Vec::from_raw_parts(list.data, list.len, list.capacity);
    }
}

/// Fix 1: Free a CHourSlotList returned by ffi_generate_hour_slots.
#[no_mangle]
pub extern "C" fn ffi_free_hour_slot_list(list: CHourSlotList) {
    if list.data.is_null() { return; }
    unsafe {
        let _ = Vec::from_raw_parts(list.data, list.len, list.capacity);
    }
}

/// Fix 1: Free a CU32List returned by ffi_task_counts_by_hour / ffi_calculate_year_heatmap.
#[no_mangle]
pub extern "C" fn ffi_free_u32_list(list: CU32List) {
    if list.data.is_null() { return; }
    unsafe {
        let _ = Vec::from_raw_parts(list.data, list.len, list.capacity);
    }
}

/// Legacy string free (kept for backward compat with any remaining callers).
#[no_mangle]
pub extern "C" fn ffi_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)); }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// C-ABI ENGINE / TASK EXPORTS
// ─────────────────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ffi_health_check() -> *const c_char {
    static VERSION: &[u8] = b"SLATE Core Engine v4.1.0 - Phase 4 [FFI | zero-copy | async-db]\0";
    VERSION.as_ptr() as *const c_char
}

/// Initialize the offline engine via C-ABI.
#[no_mangle]
pub extern "C" fn ffi_init_engine(
    db_path_ptr: *const c_char,
    supabase_url_ptr: *const c_char,
    supabase_key_ptr: *const c_char,
    db_key_ptr: *const c_char,
) -> i32 {
    let db_path      = unsafe { safe_cstr_to_string(db_path_ptr) };
    let supabase_url = unsafe { safe_cstr_to_string(supabase_url_ptr) };
    let supabase_key = unsafe { safe_cstr_to_string(supabase_key_ptr) };
    let db_key       = unsafe { safe_cstr_to_string(db_key_ptr) };

    init_engine(db_path, supabase_url, supabase_key, db_key)
}

/// Graceful shutdown — called from Dart when the window is closing.
/// 1. Stops the sync worker (joins its thread).
/// 2. Drains any writes still queued for the db-writer thread, applying them here
///    so nothing typed in the last instant is lost.
/// 3. Checkpoints the WAL (TRUNCATE) so tasks.db is self-contained on disk.
/// Safe to call multiple times; a race with the db-writer thread is harmless
/// (both sides apply idempotent upserts).
#[no_mangle]
pub extern "C" fn ffi_shutdown_engine() -> i32 {
    {
        let mut sync_lock = SYNC_ENGINE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut engine) = sync_lock.take() {
            engine.stop();
        }
    }
    if let Some(db) = get_db() {
        for op in DB_WRITE_QUEUE.drain() {
            match op {
                DbWriteOp::Upsert(task) => db.upsert_task(&task),
                DbWriteOp::SoftDelete { task_id, updated_at } => db.soft_delete_task(&task_id, updated_at),
                DbWriteOp::EnqueueSync { op, task_id, payload } => db.enqueue_op(op, &task_id, &payload),
            }
        }
        db.checkpoint();
    }
    0
}

/// Get all tasks as CTaskList. Caller must free with ffi_free_task_list.
#[no_mangle]
pub extern "C" fn ffi_get_all_tasks() -> CTaskList {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    let tasks = store.all_tasks();
    CTaskList::from_vec(tasks)
}

// Phase-2 JSON C-ABI shims (ffi_init_task_store / ffi_add_task) were removed:
// they were `#[no_mangle]` exported symbols that parsed a caller-supplied
// (ptr, len) as JSON — dead (Dart never bound them) and pure attack surface.
// The live paths are ffi_init_engine() (loads from SQLite) and
// ffi_create_task() / ffi_create_task_ex().

#[no_mangle]
pub extern "C" fn ffi_remove_task(id_ptr: *const c_char) -> i32 {
    let id = unsafe { safe_cstr_to_string(id_ptr) };
    if id.is_empty() { return -1; }
    remove_task(id) // day-list index for the undo snapshot, -1 if unknown
}

/// Undo path: recreate a deleted task with FULL state at its original
/// day-list position. Caller must free the returned task with ffi_free_task.
#[no_mangle]
pub extern "C" fn ffi_restore_task(
    title_ptr: *const c_char,
    created_at: i64,
    start_time: i64,
    end_time: i64,
    priority: u8,
    tags_ptr: *const *const c_char,
    tag_count: usize,
    is_inbox: i32,
    is_completed: i32,
    day_index: i32,
) -> *mut CTask {
    let title = unsafe { safe_cstr_to_string(title_ptr) };
    if title.trim().is_empty() { return std::ptr::null_mut(); }
    let tag_count = tag_count.min(100);
    let tags: Vec<String> = if !tags_ptr.is_null() && tag_count > 0 {
        let tag_slice = unsafe { std::slice::from_raw_parts(tags_ptr, tag_count) };
        tag_slice.iter()
            .filter_map(|&ptr| {
                if ptr.is_null() { return None; }
                unsafe { CStr::from_ptr(ptr) }.to_str().ok().map(|s| s.to_string())
            })
            .collect()
    } else {
        Vec::new()
    };

    let task = restore_task(
        title,
        created_at,
        if start_time >= 0 { Some(start_time) } else { None },
        if end_time >= 0 { Some(end_time) } else { None },
        priority,
        tags,
        is_inbox != 0,
        is_completed != 0,
        day_index.max(0) as usize,
    );
    Box::into_raw(Box::new(CTask::from_rust_task(&task)))
}

#[no_mangle]
pub extern "C" fn ffi_create_task(title_ptr: *const c_char, now_ts: i64) -> *mut CTask {
    let title = unsafe { safe_cstr_to_string(title_ptr) };
    if title.is_empty() { return std::ptr::null_mut(); }
    let task = create_task(title, now_ts);
    Box::into_raw(Box::new(CTask::from_rust_task(&task)))
}

/// Create an Inbox task and return its pointer. Caller must free with ffi_free_task.
#[no_mangle]
pub extern "C" fn ffi_create_inbox_task(title_ptr: *const c_char, now_ts: i64) -> *mut CTask {
    let title = unsafe { safe_cstr_to_string(title_ptr) };
    if title.is_empty() { return std::ptr::null_mut(); }
    let task = create_inbox_task(title, now_ts);
    Box::into_raw(Box::new(CTask::from_rust_task(&task)))
}

#[no_mangle]
pub extern "C" fn ffi_toggle_task(id_ptr: *const c_char) -> *mut CTask {
    let id = unsafe { safe_cstr_to_string(id_ptr) };
    if id.is_empty() { return std::ptr::null_mut(); }
    if let Some(task) = toggle_task(id) {
        Box::into_raw(Box::new(CTask::from_rust_task(&task)))
    } else {
        std::ptr::null_mut()
    }
}

#[no_mangle]
pub extern "C" fn ffi_task_count() -> u32 {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    store.len() as u32
}

#[no_mangle]
pub extern "C" fn ffi_tasks_for_date(date_ts: i64) -> CTaskList {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    let day_start = TaskStore::day_start_ms(date_ts);
    let tasks = store.tasks_for_day_start(day_start);
    CTaskList::from_vec(tasks)
}

// ─────────────────────────────────────────────────────────────────────────────
// C-ABI PHYSICS / SCALAR EXPORTS (unchanged scalar returns — no allocation)
// ─────────────────────────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn ffi_calculate_magnetic_snap(
    scroll_offset: f64, velocity: f64, day_boundary_offset: f64,
) -> f64 {
    spatial::calculate_magnetic_snap(scroll_offset, velocity, day_boundary_offset)
}

#[no_mangle]
pub extern "C" fn ffi_calculate_day_transition_opacity(
    scroll_offset: f64, day_boundary: f64,
) -> f64 {
    calculate_day_transition_opacity(scroll_offset, day_boundary)
}

#[no_mangle]
pub extern "C" fn ffi_calculate_spring_snap(
    scroll_offset: f64, velocity: f64, day_boundary_offset: f64, dt: f64, out_offset: *mut f64,
) -> f64 {
    let (new_offset, new_velocity) = calculate_spring_snap(scroll_offset, velocity, day_boundary_offset, dt);
    if !out_offset.is_null() { unsafe { *out_offset = new_offset; } }
    new_velocity
}

#[no_mangle]
pub extern "C" fn ffi_calculate_clock_hands(
    now_ms: i64, out_hour: *mut f64, out_minute: *mut f64,
) -> f64 {
    let (hour_deg, minute_deg, second_deg) = spatial::calculate_clock_hand_angles(now_ms);
    if !out_hour.is_null()   { unsafe { *out_hour = hour_deg; } }
    if !out_minute.is_null() { unsafe { *out_minute = minute_deg; } }
    second_deg
}

#[no_mangle]
pub extern "C" fn ffi_calculate_month_density(task_count: u32, max_expected: u32) -> f64 {
    spatial::calculate_month_density(task_count, max_expected)
}

#[no_mangle]
pub extern "C" fn ffi_calculate_drag_snap(drag_x: f64, day_column_width: f64, num_days: u8) -> u8 {
    spatial::calculate_drag_snap(drag_x, day_column_width, num_days)
}

// ─────────────────────────────────────────────────────────────────────────────
// Fix 1: SPATIAL C-ABI EXPORTS — Native structs, zero JSON
// ─────────────────────────────────────────────────────────────────────────────

/// Fix 1: Returns CSpatialFrame (pure C struct) instead of JSON string.
/// Dart reads fields directly via Struct — zero heap allocation, zero decode.
#[no_mangle]
pub extern "C" fn ffi_calculate_flow_frame(
    selected_date_ts: i64, viewport_width: f64, scroll_offset: f64,
) -> CSpatialFrame {
    let frame = calculate_flow_frame(selected_date_ts, viewport_width, scroll_offset);
    CSpatialFrame::from_rust(&frame)
}

/// Fix 1: Returns CHourSlotList (C pointer + len) instead of JSON string.
/// Task counts are passed as a raw u32 array (not JSON-encoded).
/// Caller must free with ffi_free_hour_slot_list.
#[no_mangle]
pub extern "C" fn ffi_generate_hour_slots(
    selected_date_ts: i64, viewport_width: f64, scroll_offset: f64,
    counts_ptr: *const u32, counts_len: usize,
) -> CHourSlotList {
    // Fix 1: read task counts as raw u32 array — not JSON
    let task_counts: Vec<u32> = if !counts_ptr.is_null() && counts_len > 0 {
        unsafe { std::slice::from_raw_parts(counts_ptr, counts_len) }.to_vec()
    } else {
        Vec::new()
    };
    let slots = generate_hour_slots(selected_date_ts, viewport_width, scroll_offset, task_counts);
    CHourSlotList::from_vec(slots)
}

/// Fix 1: Returns CDayCellList instead of JSON string.
/// Caller must free with ffi_free_day_cell_list.
#[no_mangle]
pub extern "C" fn ffi_generate_week_cells(current_date_ts: i64) -> CDayCellList {
    // Build skeleton cells from spatial engine
    let mut cells = generate_week_cells(current_date_ts);
    // Hydrate real task counts from the store in a single read lock
    {
        let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
        for cell in cells.iter_mut() {
            let day_start = TaskStore::day_start_ms(cell.date_timestamp);
            let day_tasks = store.tasks_for_day_start(day_start);
            cell.task_count = day_tasks.len() as u32;
            cell.completed_count = day_tasks.iter().filter(|t| t.is_completed).count() as u32;
        }
    }
    CDayCellList::from_vec(cells)
}

/// Fix 1: Returns CMonthCellList (42 slots, is_valid flag for padding) instead of JSON.
/// Caller must free with ffi_free_month_cell_list.
#[no_mangle]
pub extern "C" fn ffi_generate_month_cells(year: i32, month: u32) -> CMonthCellList {
    // Build skeleton cells (Some/None for grid padding)
    let mut cells = generate_month_cells(year, month);
    // Hydrate real task counts
    {
        let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
        for opt_cell in cells.iter_mut() {
            if let Some(cell) = opt_cell {
                let day_start = TaskStore::day_start_ms(cell.date_timestamp);
                let day_tasks = store.tasks_for_day_start(day_start);
                cell.task_count = day_tasks.len() as u32;
                cell.completed_count = day_tasks.iter().filter(|t| t.is_completed).count() as u32;
            }
        }
    }

    // Convert Vec<Option<DayCell>> → Vec<COptDayCell>
    let c_cells: Vec<COptDayCell> = cells.iter().map(|opt| {
        match opt {
            Some(c) => COptDayCell {
                cell: CDayCell::from_rust(c),
                is_valid: 1,
                _pad: [0; 7],
            },
            None => COptDayCell {
                cell: CDayCell {
                    date_timestamp: 0, day_of_week: 0, day_of_month: 0,
                    is_today: false, task_count: 0, completed_count: 0, _pad: [0; 2],
                },
                is_valid: 0,
                _pad: [0; 7],
            },
        }
    }).collect();

    let mut c_cells = std::mem::ManuallyDrop::new(c_cells);
    CMonthCellList {
        data: c_cells.as_mut_ptr(),
        len: c_cells.len(),
        capacity: c_cells.capacity(),
    }
}

/// Fix 1: ffi_task_counts_by_hour returns CU32List (raw u32 array).
/// Caller must free with ffi_free_u32_list.
#[no_mangle]
pub extern "C" fn ffi_task_counts_by_hour(date_ts: i64) -> CU32List {
    let counts = task_counts_by_hour(date_ts);
    CU32List::from_vec(counts)
}

#[no_mangle]
pub extern "C" fn ffi_tasks_for_hour(date_ts: i64, hour: u8) -> CTaskList {
    let tasks = tasks_for_hour(date_ts, hour);
    CTaskList::from_vec(tasks)
}

/// Fix 1: ffi_calculate_year_heatmap returns CU32List (raw u32 array).
/// Caller must free with ffi_free_u32_list.
#[no_mangle]
pub extern "C" fn ffi_calculate_year_heatmap(year: i32) -> CU32List {
    let heatmap = calculate_year_heatmap(year);
    CU32List::from_vec(heatmap)
}

// ffi_get_top_priority_tasks and ffi_wipe_all_tasks were removed: neither was
// called from the UI, and wipe was a destructive exported entry point sitting
// unused in the DLL. Their Dart bindings are removed in the same change — the
// bridge binds symbols in one try/catch, so a missing symbol would otherwise
// disable ALL of FFI.

// ─────────────────────────────────────────────────────────────────────────────
// PHASE 5: SMART DAY INPUT — EXTENDED CREATE
// ─────────────────────────────────────────────────────────────────────────────

/// Create a task with NLP-parsed fields (start_time, end_time, priority, tags).
/// This is the primary creation path for the Smart Day Input.
///
/// Parameters:
///   title_ptr    — cleaned title string (NUL-terminated, not raw input)
///   now_ts       — target day timestamp in milliseconds
///   start_time   — minutes since midnight (0..1439), or -1 for unset
///   end_time     — minutes since midnight (0..1439), or -1 for unset
///   priority     — 0=Normal, 1=Important, 2=Very Important
///   tags_ptr     — array of NUL-terminated tag strings (Caller-owned; Caller frees after this call)
///   tag_count    — number of elements in tags_ptr
///
/// Zero-Copy: no JSON encoding/decoding on this path.
/// Caller-Frees: the tags_ptr array and its strings are owned by the Dart caller (calloc).
///              The returned *mut CTask is owned by Rust (heap) — Caller must free with ffi_free_task.
#[no_mangle]
pub extern "C" fn ffi_create_task_ex(
    title_ptr: *const c_char,
    now_ts: i64,
    start_time: i64,
    end_time: i64,
    priority: u8,
    tags_ptr: *const *const c_char,
    tag_count: usize,
) -> *mut CTask {
    let title = unsafe { safe_cstr_to_string(title_ptr) };
    if title.trim().is_empty() { return std::ptr::null_mut(); }
    let tag_count = tag_count.min(100); // Cap tags to prevent abuse

    // Read tag strings directly from the caller's pointer array — zero JSON, zero heap copy.
    let tags: Vec<String> = if !tags_ptr.is_null() && tag_count > 0 {
        let tag_slice = unsafe { std::slice::from_raw_parts(tags_ptr, tag_count) };
        tag_slice.iter()
            .filter_map(|&ptr| {
                if ptr.is_null() { return None; }
                unsafe { CStr::from_ptr(ptr) }.to_str().ok().map(|s| s.to_string())
            })
            .collect()
    } else {
        Vec::new()
    };

    let now = chrono::Utc::now().timestamp_millis();
    let id = uuid::Uuid::new_v4().to_string();

    let task = RustTask {
        id,
        title: clamp_title(title),
        is_completed: false,
        created_at: now_ts,
        updated_at: now,
        start_at: None,
        end_at: None,
        user_id: None,
        is_inbox: false,
        start_time: if start_time >= 0 { Some(start_time) } else { None },
        end_time: if end_time >= 0 { Some(end_time) } else { None },
        tags,
        priority: priority.min(2),
    };

    {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        store.insert(task.clone());
    }

    async_upsert(&task);
    async_enqueue_sync(SyncOp::Create, &task.id, &task);
    // Only touches the DB when the stated time is already behind us, which is
    // rare — the common capture ("meeting at 18") is in the future and this is
    // a no-op, so the write queue stays the hot path it was built to be.
    seal_past_slot(&task, now);

    Box::into_raw(Box::new(CTask::from_rust_task(&task)))
}

/// Update an existing task IN-PLACE with edited fields (title, assigned day, start/end
/// time, priority, tags). Mirrors `ffi_create_task_ex` but mutates the task identified by
/// `id` instead of creating a new one. Preserves completion, owner and the absolute
/// start_at/end_at fields; `is_inbox` is set explicitly (-1 preserves the current value,
/// used by drag-and-drop to move inbox tasks onto the calendar); reindexes automatically
/// if the assigned day changed.
///
/// This replaces the old "remove without re-insert" update path that made edited tasks
/// vanish from the store. Returns the updated task pointer (caller frees with
/// `ffi_free_task`), or null if no task with that id exists.
#[no_mangle]
pub extern "C" fn ffi_update_task_ex(
    id_ptr: *const c_char,
    title_ptr: *const c_char,
    day_ts: i64,
    start_time: i64,
    end_time: i64,
    priority: u8,
    tags_ptr: *const *const c_char,
    tag_count: usize,
    is_inbox: i32, // -1 preserve, 0 clear, 1 set
) -> *mut CTask {
    let id = unsafe { safe_cstr_to_string(id_ptr) };
    if id.is_empty() { return std::ptr::null_mut(); }
    let title = unsafe { safe_cstr_to_string(title_ptr) };
    if title.trim().is_empty() { return std::ptr::null_mut(); }
    let tag_count = tag_count.min(100); // Cap tags to prevent abuse

    let tags: Vec<String> = if !tags_ptr.is_null() && tag_count > 0 {
        let tag_slice = unsafe { std::slice::from_raw_parts(tags_ptr, tag_count) };
        tag_slice.iter()
            .filter_map(|&ptr| {
                if ptr.is_null() { return None; }
                unsafe { CStr::from_ptr(ptr) }.to_str().ok().map(|s| s.to_string())
            })
            .collect()
    } else {
        Vec::new()
    };

    let now = chrono::Utc::now().timestamp_millis();

    let updated = {
        let mut store = TASK_STORE.write().unwrap_or_else(|e| e.into_inner());
        match store.tasks.get(&id).cloned() {
            Some(existing) => {
                let new_task = RustTask {
                    id: existing.id.clone(),
                    title: clamp_title(title),
                    is_completed: existing.is_completed,
                    created_at: day_ts,
                    updated_at: now,
                    start_at: existing.start_at,
                    end_at: existing.end_at,
                    user_id: existing.user_id.clone(),
                    is_inbox: if is_inbox < 0 { existing.is_inbox } else { is_inbox != 0 },
                    start_time: if start_time >= 0 { Some(start_time) } else { None },
                    end_time: if end_time >= 0 { Some(end_time) } else { None },
                    tags,
                    priority: priority.min(2),
                };
                store.update(new_task.clone()); // remove+insert → reindexes by day
                Some(new_task)
            }
            None => None,
        }
    };

    match updated {
        Some(task) => {
            async_upsert(&task);
            async_enqueue_sync(SyncOp::Update, &task.id, &task);
            // Dropped onto an hour that already passed: seal it, or the card
            // would fire the instant the drag ends.
            seal_past_slot(&task, chrono::Utc::now().timestamp_millis());
            Box::into_raw(Box::new(CTask::from_rust_task(&task)))
        }
        None => std::ptr::null_mut(),
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// REMINDERS
//
// One rule: a time IS the request to be reminded. A task carrying start_time
// gets a slot; a task without one stays silent forever. Priority (!/!!) is
// deliberately never consulted — importance and wanting to be interrupted are
// different axes, and taxing the capture with an extra keystroke is exactly the
// friction this product exists to remove.
//
// The slot is DERIVED (day + start_time - lead), never stored. What is stored is
// which slot already spoke (reminder_log), so moving a task to a new time makes
// it unspoken again for free.
// ═══════════════════════════════════════════════════════════════════════════════

/// Five minutes early. A reminder that lands after the point where the person
/// could still act on it stops being help and becomes a reproach; zero lead is
/// a notice of lateness, and the ten-to-fifteen calendars use is "time to walk
/// to the meeting room" — which is not what this is.
pub const REMINDER_LEAD_MS: i64 = 5 * 60_000;

/// How late is still worth saying out loud. Past this the moment is gone and we
/// stay quiet on purpose — the day itself carries the task from there.
pub const REMINDER_GRACE_MS: i64 = 120_000;

/// A task born — or moved — after its own moment must not shout two seconds
/// later. Typing "call at 15:00" at 14:58 seals the 14:55 slot as already
/// spoken, which also covers dragging a task onto an hour that has passed.
fn seal_past_slot(task: &RustTask, now_ms: i64) {
    if let Some(slot) = reminder_slot_ms(task, REMINDER_LEAD_MS) {
        if slot <= now_ms {
            if let Some(db) = get_db() {
                db.mark_reminded(&task.id, slot, now_ms);
            }
        }
    }
}

/// The absolute moment this task asks to be announced, or None if it never does.
///
/// `start_time` is WALL-CLOCK ("18:00"), so the moment is resolved through the
/// local calendar, never as `midnight + minutes`. On the two days a year the
/// clocks move, a day is 23 or 25 hours long and that arithmetic silently lands
/// an hour off. This is also why the calculation lives here and is never
/// duplicated in Dart.
pub fn reminder_slot_ms(task: &RustTask, lead_ms: i64) -> Option<i64> {
    if task.is_completed || task.is_inbox {
        return None;
    }
    let minutes = task.start_time?;
    if !(0..=1439).contains(&minutes) {
        return None;
    }
    use chrono::{Local, TimeZone};
    let secs = task.created_at / 1000;
    let nsecs = ((task.created_at % 1000) * 1_000_000) as u32;
    let wall = Local
        .timestamp_opt(secs, nsecs)
        .earliest()
        .and_then(|dt| {
            dt.date_naive()
                .and_hms_opt((minutes / 60) as u32, (minutes % 60) as u32, 0)
        })
        // Spring-forward skips an hour: a task sitting inside the gap has no
        // real moment. Falling back to plain arithmetic keeps it audible —
        // an hour of drift once a year beats silence.
        .and_then(|naive| naive.and_local_timezone(Local).earliest())
        .map(|dt| dt.timestamp_millis())
        .unwrap_or_else(|| TaskStore::day_start_ms(task.created_at) + minutes * 60_000);
    Some(wall - lead_ms)
}

/// Slots that have come due and have not been spoken yet.
///
/// `grace_ms` is how late is still worth saying out loud. Past it we stay quiet
/// on purpose: a reminder arriving after the point where the person could still
/// act on it stops being help and becomes a reproach — the day view picks those
/// up instead. Pure function, no globals: this is the part worth testing.
pub fn due_reminders(
    tasks: &[RustTask],
    reminded: &HashMap<String, i64>,
    now_ms: i64,
    lead_ms: i64,
    grace_ms: i64,
) -> Vec<(RustTask, i64)> {
    let mut out: Vec<(RustTask, i64)> = tasks
        .iter()
        .filter_map(|t| reminder_slot_ms(t, lead_ms).map(|slot| (t, slot)))
        .filter(|(_, slot)| *slot <= now_ms && *slot > now_ms - grace_ms)
        .filter(|(t, slot)| reminded.get(&t.id) != Some(slot))
        .map(|(t, slot)| (t.clone(), slot))
        .collect();
    out.sort_by_key(|(_, slot)| *slot);
    out
}

/// The next slot strictly in the future, or None if the day holds nothing more.
/// The scheduler sleeps on this instead of polling blindly.
pub fn next_reminder_ms(tasks: &[RustTask], now_ms: i64, lead_ms: i64) -> Option<i64> {
    tasks
        .iter()
        .filter_map(|t| reminder_slot_ms(t, lead_ms))
        .filter(|slot| *slot > now_ms)
        .min()
}

/// A single announcement, flattened for the ABI. Caller frees the whole list
/// with `ffi_free_reminder_list` (Caller-Frees protocol).
#[repr(C)]
pub struct CReminder {
    pub id: *mut c_char,
    pub title: *mut c_char,
    /// The moment we speak (start minus lead). This IS the announcement's
    /// identity — Dart hands it back to `ffi_mark_reminded` unchanged.
    pub slot_ms: i64,
    /// Local midnight of the task's day, so a click can open exactly that day.
    pub day_start_ms: i64,
    /// Minutes since midnight — renders "18:00" without recomputing the day.
    pub start_time: i64,
    /// 0 = normal, 1 = `!`, 2 = `!!`. It does NOT decide whether we speak — a
    /// time alone does that. It decides how long the card waits: a banner that
    /// leaves on its own, or one that waits to be noticed.
    pub priority: u8,
}

#[repr(C)]
pub struct CReminderList {
    pub data: *mut CReminder,
    pub len: usize,
    pub capacity: usize,
}

impl CReminderList {
    fn from_vec(items: Vec<(RustTask, i64)>) -> Self {
        let mut c_items: Vec<CReminder> = items
            .into_iter()
            .map(|(t, slot)| CReminder {
                id: CString::new(t.id.clone()).unwrap_or_default().into_raw(),
                title: CString::new(t.title.clone()).unwrap_or_default().into_raw(),
                slot_ms: slot,
                day_start_ms: TaskStore::day_start_ms(t.created_at),
                start_time: t.start_time.unwrap_or(-1),
                priority: t.priority.min(2),
            })
            .collect();
        let mut c_items = std::mem::ManuallyDrop::new(c_items);
        Self {
            data: c_items.as_mut_ptr(),
            len: c_items.len(),
            capacity: c_items.capacity(),
        }
    }
}

/// Announcements that have come due. Empty list is the normal answer.
///
/// Lead and grace are NOT parameters on purpose: a number that lives in two
/// languages eventually disagrees with itself. Rust owns them; Dart owns when
/// to ask.
#[no_mangle]
pub extern "C" fn ffi_due_reminders(now_ms: i64) -> CReminderList {
    let reminded = match get_db() {
        Some(db) => db.reminded_slots(),
        None => HashMap::new(),
    };
    let tasks = {
        let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
        store.all_tasks()
    };
    CReminderList::from_vec(due_reminders(
        &tasks,
        &reminded,
        now_ms,
        REMINDER_LEAD_MS,
        REMINDER_GRACE_MS,
    ))
}

/// Next future slot in ms, or -1 when there is nothing left to wait for.
#[no_mangle]
pub extern "C" fn ffi_next_reminder_at(now_ms: i64) -> i64 {
    let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
    next_reminder_ms(&store.all_tasks(), now_ms, REMINDER_LEAD_MS).unwrap_or(-1)
}

/// Record that this exact slot has spoken, so it never speaks twice — including
/// across restarts. Prunes stale rows on the way out; it runs at most once per
/// announcement, so a single DELETE here costs nothing.
#[no_mangle]
pub extern "C" fn ffi_mark_reminded(task_id: *const c_char, slot_ms: i64, now_ms: i64) -> bool {
    let id = unsafe { safe_cstr_to_string(task_id) };
    if id.is_empty() {
        return false;
    }
    match get_db() {
        Some(db) => {
            db.mark_reminded(&id, slot_ms, now_ms);
            db.prune_reminder_log(now_ms - 7 * 86_400_000);
            true
        }
        None => false,
    }
}

/// Seal a task's slot without waiting for it: this task will not speak.
///
/// Used for the first-run samples, which carry today's times — a brand-new user
/// must not be reminded about a coffee with someone who does not exist. The slot
/// is computed HERE so the daylight-saving arithmetic stays in one place.
#[no_mangle]
pub extern "C" fn ffi_seal_reminder(task_id: *const c_char, now_ms: i64) -> bool {
    let id = unsafe { safe_cstr_to_string(task_id) };
    if id.is_empty() {
        return false;
    }
    let task = {
        let store = TASK_STORE.read().unwrap_or_else(|e| e.into_inner());
        store.tasks.get(&id).cloned()
    };
    let Some(task) = task else { return false };
    // No time means it never speaks anyway — nothing to seal.
    let Some(slot) = reminder_slot_ms(&task, REMINDER_LEAD_MS) else {
        return false;
    };
    match get_db() {
        Some(db) => {
            db.mark_reminded(&id, slot, now_ms);
            true
        }
        None => false,
    }
}

/// Caller-Frees: reclaim every string and the backing array.
#[no_mangle]
pub extern "C" fn ffi_free_reminder_list(list: CReminderList) {
    if list.data.is_null() {
        return;
    }
    unsafe {
        let vec = Vec::from_raw_parts(list.data, list.len, list.capacity);
        for r in vec {
            if !r.id.is_null() {
                drop(CString::from_raw(r.id));
            }
            if !r.title.is_null() {
                drop(CString::from_raw(r.title));
            }
        }
    }
}

#[cfg(test)]
mod reminder_tests {
    use super::*;

    const LEAD: i64 = 5 * 60_000;   // the shipped five minutes
    const GRACE: i64 = 90_000;      // still worth saying out loud

    fn at(minutes: i64) -> RustTask {
        RustTask {
            id: format!("t{}", minutes),
            title: "task".into(),
            start_time: Some(minutes),
            ..Default::default()
        }
    }

    fn slot_of(t: &RustTask) -> i64 {
        reminder_slot_ms(t, LEAD).expect("task was built with a time")
    }

    /// Local wall-clock (hour, minute) of an epoch-ms instant.
    fn wall_of(ms: i64) -> (u32, u32) {
        use chrono::{Local, TimeZone, Timelike};
        let dt = Local.timestamp_opt(ms / 1000, 0).earliest().expect("valid instant");
        (dt.hour(), dt.minute())
    }

    #[test]
    fn a_time_asks_to_be_reminded_five_minutes_early() {
        // Asserted in wall-clock, not in arithmetic: 18:00 minus the lead must
        // READ as 17:55 on the clock the person is looking at.
        let t = at(18 * 60);
        assert_eq!(wall_of(slot_of(&t) + LEAD), (18, 0));
        assert_eq!(wall_of(slot_of(&t)), (17, 55));
    }

    #[test]
    fn every_day_of_the_year_lands_on_the_stated_wall_clock() {
        // The DST guard. Walk a whole year in local days — including whichever
        // two shift the clocks in this machine's zone — and require the moment
        // to keep reading as 18:00. `midnight + minutes` fails this on the
        // 23- and 25-hour days.
        let base = chrono::Utc::now().timestamp_millis();
        for day in 0..365 {
            let t = RustTask {
                id: format!("d{}", day),
                start_time: Some(18 * 60),
                created_at: base + day * 86_400_000,
                ..Default::default()
            };
            let fire = slot_of(&t) + LEAD;
            assert_eq!(wall_of(fire), (18, 0), "day offset {} drifted", day);
        }
    }

    #[test]
    fn no_time_means_silence_forever() {
        let t = RustTask { start_time: None, ..Default::default() };
        assert_eq!(reminder_slot_ms(&t, LEAD), None);
    }

    #[test]
    fn priority_does_not_touch_reminders() {
        // The whole product decision in one assertion: !! and plain agree.
        let plain = at(9 * 60);
        let shouted = RustTask { priority: 2, ..at(9 * 60) };
        assert_eq!(
            reminder_slot_ms(&plain, LEAD),
            reminder_slot_ms(&shouted, LEAD)
        );
    }

    #[test]
    fn a_shouted_task_without_a_time_still_stays_silent() {
        let t = RustTask { priority: 2, start_time: None, ..Default::default() };
        assert_eq!(reminder_slot_ms(&t, LEAD), None);
    }

    #[test]
    fn done_and_inbox_never_speak() {
        let done = RustTask { is_completed: true, ..at(10 * 60) };
        let inbox = RustTask { is_inbox: true, ..at(10 * 60) };
        assert_eq!(reminder_slot_ms(&done, LEAD), None);
        assert_eq!(reminder_slot_ms(&inbox, LEAD), None);
    }

    #[test]
    fn out_of_range_minutes_are_refused() {
        let bad = RustTask { start_time: Some(1440), ..Default::default() };
        assert_eq!(reminder_slot_ms(&bad, LEAD), None);
    }

    #[test]
    fn due_within_grace_speaks_but_older_stays_quiet() {
        let t = at(12 * 60);
        let slot = slot_of(&t);
        let empty = HashMap::new();
        let tasks = vec![t];

        // Exactly on time, and a moment late — both still actionable.
        assert_eq!(due_reminders(&tasks, &empty, slot, LEAD, GRACE).len(), 1);
        assert_eq!(due_reminders(&tasks, &empty, slot + 60_000, LEAD, GRACE).len(), 1);
        // Past the grace window: the moment is gone, so we say nothing.
        assert!(due_reminders(&tasks, &empty, slot + GRACE, LEAD, GRACE).is_empty());
        // Not yet.
        assert!(due_reminders(&tasks, &empty, slot - 1, LEAD, GRACE).is_empty());
    }

    #[test]
    fn a_spoken_slot_never_speaks_twice() {
        let t = at(15 * 60);
        let slot = slot_of(&t);
        let tasks = vec![t.clone()];
        let mut log = HashMap::new();
        log.insert(t.id.clone(), slot);
        assert!(due_reminders(&tasks, &log, slot, LEAD, GRACE).is_empty());
    }

    #[test]
    fn moving_a_task_makes_it_unspoken_again() {
        // The reason the log stores WHICH slot instead of a done flag: no edit
        // hook has to remember to reset anything.
        let moved = at(20 * 60);
        let mut log = HashMap::new();
        log.insert(moved.id.clone(), slot_of(&moved) - 2 * 3_600_000); // old 18:00
        let slot = slot_of(&moved);
        assert_eq!(due_reminders(&[moved], &log, slot, LEAD, GRACE).len(), 1);
    }

    #[test]
    fn due_list_is_ordered_by_moment() {
        let early = at(8 * 60);
        let late = at(17 * 60);
        let now = slot_of(&late);
        let out = due_reminders(&[late, early], &HashMap::new(), now, LEAD, GRACE * 1000);
        let slots: Vec<i64> = out.iter().map(|(_, s)| *s).collect();
        let mut sorted = slots.clone();
        sorted.sort();
        assert_eq!(slots, sorted);
    }

    #[test]
    fn next_moment_is_the_nearest_future_one() {
        let soon = at(11 * 60);
        let later = at(16 * 60);
        let base = slot_of(&soon) - 1;
        assert_eq!(
            next_reminder_ms(&[later.clone(), soon.clone()], base, LEAD),
            Some(slot_of(&soon))
        );
        // Past the first one, the next is the later task.
        assert_eq!(
            next_reminder_ms(&[later.clone(), soon.clone()], slot_of(&soon), LEAD),
            Some(slot_of(&later))
        );
        // Nothing left today.
        assert_eq!(next_reminder_ms(&[soon, later.clone()], slot_of(&later), LEAD), None);
    }

    #[test]
    fn nothing_scheduled_means_nothing_to_wait_for() {
        let idle = RustTask { start_time: None, ..Default::default() };
        assert_eq!(next_reminder_ms(&[idle], 0, LEAD), None);
    }
}
