//! Ghost Task Migration Engine
//! High-performance filtering and processing of overdue tasks

use crate::types::{RustTask, GhostTask};
use chrono::{DateTime, Local, Utc, Datelike, TimeZone, Timelike};
use rayon::prelude::*;

/// Filter and process ghost tasks from a task list
/// Uses parallel processing for large datasets
pub fn extract_ghost_tasks(tasks: Vec<RustTask>, now_ts: i64) -> Vec<GhostTask> {
    let now = timestamp_to_datetime(now_ts);
    let today_start = now.date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|dt| dt.and_local_timezone(Local).single())
        .unwrap_or(now);
    
    // Use rayon for parallel filtering when dataset is large
    if tasks.len() > 100 {
        tasks
            .into_par_iter()
            .filter_map(|task| {
                if !task.is_completed {
                    let task_date = task.created_datetime();
                    if task_date < today_start {
                        let days_overdue = (today_start - task_date).num_days() as i32;
                        return Some(GhostTask {
                            original_date: task.created_at,
                            days_overdue,
                            task,
                        });
                    }
                }
                None
            })
            .collect()
    } else {
        tasks
            .into_iter()
            .filter_map(|task| {
                if !task.is_completed {
                    let task_date = task.created_datetime();
                    if task_date < today_start {
                        let days_overdue = (today_start - task_date).num_days() as i32;
                        return Some(GhostTask {
                            original_date: task.created_at,
                            days_overdue,
                            task,
                        });
                    }
                }
                None
            })
            .collect()
    }
}

/// Sort ghost tasks by priority (oldest first)
pub fn sort_ghosts_by_age(mut ghosts: Vec<GhostTask>) -> Vec<GhostTask> {
    ghosts.sort_by(|a, b| b.days_overdue.cmp(&a.days_overdue));
    ghosts
}

/// Filter tasks for a specific date
pub fn tasks_for_date(tasks: &[RustTask], date_ts: i64) -> Vec<RustTask> {
    let target_date = timestamp_to_datetime(date_ts).date_naive();
    
    tasks
        .iter()
        .filter(|t| t.created_datetime().date_naive() == target_date)
        .cloned()
        .collect()
}

/// Filter tasks for a specific hour on a date
pub fn tasks_for_hour(tasks: &[RustTask], date_ts: i64, hour: u8) -> Vec<RustTask> {
    let target_date = timestamp_to_datetime(date_ts).date_naive();
    
    tasks
        .iter()
        .filter(|t| {
            let dt = t.created_datetime();
            if dt.date_naive() != target_date {
                return false;
            }
            if let Some(st) = t.start_time {
                let task_hour = (st / 60) as u8;
                task_hour == hour
            } else {
                false // Unallocated tasks do not belong to any specific hour
            }
        })
        .cloned()
        .collect()
}

/// Count tasks per hour for a given date (returns array of 24 counts)
pub fn task_counts_by_hour(tasks: &[RustTask], date_ts: i64) -> Vec<u32> {
    let target_date = timestamp_to_datetime(date_ts).date_naive();
    let mut counts = vec![0u32; 24];
    
    for task in tasks {
        let dt = task.created_datetime();
        if dt.date_naive() == target_date {
            if let Some(st) = task.start_time {
                let hour = (st / 60) as usize;
                if hour < 24 {
                    counts[hour] += 1;
                }
            }
        }
    }
    
    counts
}

/// Calculate task statistics for a date range
pub fn calculate_task_stats(
    tasks: &[RustTask],
    start_ts: i64,
    end_ts: i64,
) -> (u32, u32) {
    let start = timestamp_to_datetime(start_ts);
    let end = timestamp_to_datetime(end_ts);
    
    let (total, completed): (u32, u32) = tasks
        .iter()
        .filter(|t| {
            let dt = t.created_datetime();
            dt >= start && dt <= end
        })
        .fold((0, 0), |(t, c), task| {
            (t + 1, if task.is_completed { c + 1 } else { c })
        });
    
    (total, completed)
}

/// Batch update task counts for week view (parallel processing)
pub fn batch_update_week_counts(
    tasks: &[RustTask],
    week_start_ts: i64,
) -> Vec<(u32, u32)> {  // Returns (total, completed) for each day
    let week_start = timestamp_to_datetime(week_start_ts).date_naive();
    
    (0..7)
        .map(|day_offset| {
            let target = week_start + chrono::Duration::days(day_offset);
            let (total, completed) = tasks
                .iter()
                .filter(|t| t.created_datetime().date_naive() == target)
                .fold((0u32, 0u32), |(t, c), task| {
                    (t + 1, if task.is_completed { c + 1 } else { c })
                });
            (total, completed)
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper
// ─────────────────────────────────────────────────────────────────────────────

fn timestamp_to_datetime(ts: i64) -> DateTime<Local> {
    let secs = ts / 1000;
    let nsecs = ((ts % 1000) * 1_000_000) as u32;
    Local.timestamp_opt(secs, nsecs).single().unwrap_or_else(|| Local::now())
}
