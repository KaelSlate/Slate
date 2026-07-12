//! Shared types for FFI transfer between Rust and Dart
//! Phase 3: Added updated_at for LWW conflict resolution
//! Phase 4: Added is_inbox flag for explicit Inbox vs. Calendar segregation

use chrono::{DateTime, Local, Utc, TimeZone};
use serde::{Deserialize, Serialize};

/// Task representation for Rust processing
/// Phase 5: Added start_time/end_time (minutes-since-midnight for intra-day scheduling),
///          tags (Vec<String>), and priority (0=Normal, 1=Important, 2=Very Important).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RustTask {
    pub id: String,
    pub title: String,
    pub is_completed: bool,
    pub created_at: i64,   // Unix timestamp in milliseconds
    pub updated_at: i64,   // LWW timestamp in milliseconds (Phase 3)
    pub start_at: Option<i64>, // Scheduled start Unix timestamp in ms
    pub end_at: Option<i64>,   // Scheduled end Unix timestamp in ms
    pub user_id: Option<String>, // Ownership identifier for Supabase sync
    /// Phase 4: Explicit Inbox flag. true = lives in Inbox, not on calendar.
    #[serde(default)]
    pub is_inbox: bool,
    /// Phase 5: Intra-day start time as minutes since midnight (0..1439), None = unallocated.
    #[serde(default)]
    pub start_time: Option<i64>,
    /// Phase 5: Intra-day end time as minutes since midnight (0..1439), None = unallocated.
    #[serde(default)]
    pub end_time: Option<i64>,
    /// Phase 5: Tags parsed from input (e.g. ["work", "urgent"]).
    #[serde(default)]
    pub tags: Vec<String>,
    /// Phase 5: Priority level. 0=Normal, 1=Important (!), 2=Very Important (!!).
    #[serde(default)]
    pub priority: u8,
}

impl RustTask {
    pub fn created_datetime(&self) -> DateTime<Local> {
        let secs = self.created_at / 1000;
        let nsecs = ((self.created_at % 1000) * 1_000_000) as u32;
        Local.timestamp_opt(secs, nsecs).single().unwrap_or_else(|| Local::now())
    }

    /// Touch the updated_at timestamp to current time.
    pub fn touch(&mut self) {
        self.updated_at = Utc::now().timestamp_millis();
    }

    /// Whether this task has an allocated time slot.
    pub fn is_allocated(&self) -> bool {
        self.start_time.is_some()
    }
}

impl Default for RustTask {
    fn default() -> Self {
        let now = Utc::now().timestamp_millis();
        Self {
            id: String::new(),
            title: String::new(),
            is_completed: false,
            created_at: now,
            updated_at: now,
            start_at: None,
            end_at: None,
            user_id: None,
            is_inbox: false,
            start_time: None,
            end_time: None,
            tags: Vec::new(),
            priority: 0,
        }
    }
}

/// Ghost task with source date info
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GhostTask {
    pub task: RustTask,
    pub original_date: i64,  // Unix timestamp of original date
    pub days_overdue: i32,
}

/// Visible hour slot for Flow view rendering
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HourSlot {
    pub hour: u8,           // 0-23
    pub x_offset: f64,      // Pixel offset from left
    pub is_current: bool,   // Is this the current hour
    pub task_count: u32,    // Number of tasks in this hour
}

/// Day cell for Tactics view
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DayCell {
    pub date_timestamp: i64,
    pub day_of_week: u8,    // 0=Monday, 6=Sunday
    pub day_of_month: u8,
    pub is_today: bool,
    pub task_count: u32,
    pub completed_count: u32,
}

/// Spatial calculation result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpatialFrame {
    pub visible_start: i64,     // Start timestamp of visible range
    pub visible_end: i64,       // End timestamp of visible range
    pub hour_width: f64,        // Calculated hour width in pixels
    pub current_offset: f64,    // Current scroll offset
    pub total_width: f64,       // Total scrollable width
}

/// Staircase navigation level
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum StaircaseLevel {
    Strategy = 0,
    Tactics = 1,
    Planning = 2,
    Flow = 3,
}

/// View mode for Tactics level
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum TacticsMode {
    Week = 0,
    Month = 1,
}

/// Sync operation type for the dirty queue
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncOp {
    Create,
    Update,
    Delete,
}

impl SyncOp {
    pub fn as_str(&self) -> &'static str {
        match self {
            SyncOp::Create => "create",
            SyncOp::Update => "update",
            SyncOp::Delete => "delete",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "create" => Some(SyncOp::Create),
            "update" => Some(SyncOp::Update),
            "delete" => Some(SyncOp::Delete),
            _ => None,
        }
    }
}

/// A queued sync operation
#[derive(Debug, Clone)]
pub struct QueuedOp {
    pub queue_id: i64,
    pub op: SyncOp,
    pub task_id: String,
    pub payload: String,  // JSON of the task at time of mutation
    pub created_at: i64,
}
