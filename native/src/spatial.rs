//! Spatial Calculation Engine
//! High-performance zoom, offset, and visibility calculations
//! Fix 5: Zero Panic — all .unwrap() replaced with safe fallbacks.

use crate::types::{SpatialFrame, HourSlot, DayCell, StaircaseLevel, TacticsMode};
use chrono::{DateTime, Local, Utc, Datelike, Timelike, Duration, TimeZone, Weekday};

/// Constants for spatial calculations
const HOUR_WIDTH_BASE: f64 = 100.0;
const VIEWPORT_PADDING: f64 = 50.0;

/// Calculate the spatial frame for Flow view (24-hour ribbon)
pub fn calculate_flow_frame(
    selected_date_ts: i64,
    viewport_width: f64,
    scroll_offset: f64,
) -> SpatialFrame {
    let hour_width = HOUR_WIDTH_BASE;
    let total_width = 26.0 * hour_width; // 24 hours + 2 peek hours
    
    // Clamp scroll offset
    let max_offset = (total_width - viewport_width).max(0.0);
    let clamped_offset = scroll_offset.clamp(0.0, max_offset);
    
    // Calculate visible time range
    let start_hour = (clamped_offset / hour_width).floor() as i64;
    let end_hour = ((clamped_offset + viewport_width) / hour_width).ceil() as i64;
    
    let date = timestamp_to_datetime(selected_date_ts);
    // Fix 5: .unwrap() on NaiveTime→DateTime replaced with safe .unwrap_or fallback
    let start_of_day_naive = date
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .unwrap_or_else(|| date.naive_local().date().and_hms_opt(0, 0, 0)
            .unwrap_or_else(|| chrono::NaiveDate::from_ymd_opt(1970, 1, 1)
                .and_then(|d| d.and_hms_opt(0, 0, 0))
                .expect("epoch is always valid")));

    let day_start_ms = start_of_day_naive
        .and_local_timezone(Local)
        .earliest()
        .map(|dt| dt.timestamp_millis())
        .unwrap_or(0);
    
    SpatialFrame {
        visible_start: day_start_ms + (start_hour * 3600 * 1000),
        visible_end:   day_start_ms + (end_hour   * 3600 * 1000),
        hour_width,
        current_offset: clamped_offset,
        total_width,
    }
}

/// Generate hour slots for the Flow view
pub fn generate_hour_slots(
    selected_date_ts: i64,
    viewport_width: f64,
    scroll_offset: f64,
    task_counts: Vec<u32>,  // Task count per hour (0-23)
) -> Vec<HourSlot> {
    let now = Local::now();
    let selected_date = timestamp_to_datetime(selected_date_ts);
    let is_today = selected_date.date_naive() == now.date_naive();
    let current_hour = now.hour() as u8;
    
    let hour_width = HOUR_WIDTH_BASE;
    let start_hour = ((scroll_offset - VIEWPORT_PADDING) / hour_width).floor().max(0.0) as u8;
    let end_hour = (((scroll_offset + viewport_width + VIEWPORT_PADDING) / hour_width).ceil() as u8).min(26);
    
    (start_hour..end_hour)
        .map(|h| {
            let display_hour = h % 24;
            HourSlot {
                hour: display_hour,
                x_offset: (h as f64) * hour_width,
                is_current: is_today && display_hour == current_hour && h < 24,
                task_count: task_counts.get(display_hour as usize).copied().unwrap_or(0),
            }
        })
        .collect()
}

/// Generate day cells for Week Tactics view
pub fn generate_week_cells(current_date_ts: i64) -> Vec<DayCell> {
    let now = Local::now();
    let current = timestamp_to_datetime(current_date_ts);
    
    // Find Monday of this week
    let days_since_monday = current.weekday().num_days_from_monday() as i64;
    let monday = current - Duration::days(days_since_monday);
    
    (0..7)
        .map(|i| {
            let date = monday + Duration::days(i);
            DayCell {
                date_timestamp: date.timestamp_millis(),
                day_of_week: i as u8,
                day_of_month: date.day() as u8,
                is_today: date.date_naive() == now.date_naive(),
                task_count: 0,  // Filled by caller
                completed_count: 0,
            }
        })
        .collect()
}

/// Generate day cells for Month Tactics view
pub fn generate_month_cells(year: i32, month: u32) -> Vec<Option<DayCell>> {
    let now = Local::now();
    // Fix 5: .unwrap() → .single().unwrap_or_else(|| Local::now())
    let first_of_month = Local
        .with_ymd_and_hms(year, month, 1, 0, 0, 0)
        .single()
        .unwrap_or_else(|| Local::now());
    let days_in_month = days_in_month(year, month);
    let start_weekday = first_of_month.weekday().num_days_from_monday() as usize;
    
    let mut cells: Vec<Option<DayCell>> = vec![None; 42];
    
    for day in 1..=days_in_month {
        // Fix 5: .unwrap() → .single().unwrap_or_else(|| Local::now())
        let date = Local
            .with_ymd_and_hms(year, month, day, 0, 0, 0)
            .single()
            .unwrap_or_else(|| Local::now());
        let index = start_weekday + (day as usize) - 1;
        
        if index < 42 {
            cells[index] = Some(DayCell {
                date_timestamp: date.timestamp_millis(),
                day_of_week: date.weekday().num_days_from_monday() as u8,
                day_of_month: day as u8,
                is_today: date.date_naive() == now.date_naive(),
                task_count: 0,
                completed_count: 0,
            });
        }
    }
    
    cells
}

/// Calculate magnetic momentum for day boundary snapping in Flow view
pub fn calculate_magnetic_snap(
    scroll_offset: f64,
    velocity: f64,
    day_boundary_offset: f64,
) -> f64 {
    let distance_to_boundary = (scroll_offset - day_boundary_offset).abs();
    let snap_threshold = 80.0;
    let snap_strength = 0.15;
    
    if distance_to_boundary < snap_threshold && velocity.abs() < 100.0 {
        // Apply magnetic pull toward boundary
        let pull = (snap_threshold - distance_to_boundary) * snap_strength;
        if scroll_offset < day_boundary_offset {
            scroll_offset + pull
        } else {
            scroll_offset - pull
        }
    } else {
        scroll_offset
    }
}

/// Calculate zoom scale for level transitions
pub fn calculate_zoom_scale(level: StaircaseLevel, progress: f64) -> f64 {
    let base_scales = [0.25, 0.5, 1.0, 2.0];  // Strategy, Tactics, Planning, Flow
    let level_idx = level as usize;
    base_scales[level_idx] * (1.0 + (progress - 0.5) * 0.2)
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper Functions
// ─────────────────────────────────────────────────────────────────────────────

fn timestamp_to_datetime(ts: i64) -> DateTime<Local> {
    let secs = ts / 1000;
    let nsecs = ((ts % 1000) * 1_000_000) as u32;
    // Fix 5: .unwrap() → .earliest().unwrap_or_else(|| Local::now())
    Local.timestamp_opt(secs, nsecs)
        .earliest()
        .unwrap_or_else(|| Local::now())
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0) {
                29
            } else {
                28
            }
        }
        _ => 30,
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PHASE 14.0 - Strategy Heatmap & Sweeping Clock
// ═══════════════════════════════════════════════════════════════════════════════

/// Calculate task density for a given month (0.0 to 1.0)
/// Used for GitHub-style heatmap in Year/Strategy view
pub fn calculate_month_density(task_count: u32, max_expected: u32) -> f64 {
    if max_expected == 0 {
        return 0.0;
    }
    let density = (task_count as f64) / (max_expected as f64);
    density.clamp(0.0, 1.0)
}

/// Calculate task counts per month for a year
/// Returns array of 12 counts (Jan=0, Dec=11)
pub fn calculate_year_heatmap(tasks: &[crate::types::RustTask], year: i32) -> [u32; 12] {
    let mut counts = [0u32; 12];
    
    for task in tasks {
        let task_date = timestamp_to_datetime(task.created_at);
        if task_date.year() == year {
            let month_idx = (task_date.month() - 1) as usize;
            if month_idx < 12 {
                counts[month_idx] += 1;
            }
        }
    }
    
    counts
}

/// Calculate analog clock hand angles with sub-second precision
/// Returns (hour_deg, minute_deg, second_deg) for smooth sweeping hands
/// Angles are in degrees, 0 = 12 o'clock, clockwise
pub fn calculate_clock_hand_angles(now_ms: i64) -> (f64, f64, f64) {
    let total_seconds = (now_ms % 86_400_000) as f64 / 1000.0;
    let hours = total_seconds / 3600.0;
    let minutes = (total_seconds % 3600.0) / 60.0;
    let seconds = total_seconds % 60.0;
    
    // Hour hand: 360° / 12 hours = 30° per hour, plus minute fraction
    let hour_deg = (hours % 12.0) * 30.0 + (minutes / 60.0) * 30.0;
    
    // Minute hand: 360° / 60 minutes = 6° per minute, plus second fraction
    let minute_deg = minutes * 6.0 + (seconds / 60.0) * 6.0;
    
    // Second hand: 360° / 60 seconds = 6° per second (smooth sweep)
    let second_deg = seconds * 6.0;
    
    (hour_deg, minute_deg, second_deg)
}

/// Calculate magnetic snap for drag operations
/// Returns suggested drop position based on day columns
pub fn calculate_drag_snap(
    drag_x: f64,
    day_column_width: f64,
    num_days: u8,
) -> u8 {
    let column = (drag_x / day_column_width).floor() as u8;
    column.min(num_days.saturating_sub(1))
}
