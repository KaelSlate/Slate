//! Phase 5: Smart Day Input — NLP Parser Engine
//!
//! Zero-latency keystroke parser invoked from Flutter via C-ABI.
//! Input:  raw UTF-8 string from the input field
//! Output: #[repr(C)] struct with parsed tokens and cleaned title
//!
//! Parsing pipeline (applied in order):
//!   1. Priority:  `!!` → 2 (Very Important), `!` → 1 (Important), else 0
//!   2. Tags:      `#word` extracted into tags array
//!   3. Time:      Multiple patterns (see below) → start_time / end_time
//!   4. Cleanup:   Remaining text → clean_title (trimmed, no double spaces)
//!
//! Time patterns supported:
//!   - `14:00`, `14.00`
//!   - `14:00-15:30` (range)
//!   - `5pm`, `9 am`, `5:30pm`, `12am`/`12pm`
//!   - `5-6pm`, `8am-5pm`, `5pm-7` (meridiem colors the bare side)
//!   - `from 12 to 16`, `from 9 to 5pm`, `from 11pm to 2` (the English «с…до»)
//!   - `at 5` (bare 1..=7 leans PM — "at 5" means 17:00 to a human), `at 17`
//!   - `noon`, `midnight`, `полдень`, `полночь` (with or without at/в)
//!   - `на 12 июля`, `в 15.07`, `on jul 12` (a preposition before a date)
//!   - `на 14`, `в 2` (at 14, at 2)
//!   - `в 2 часа`, `в 14 часов`
//!   - `9 вечера` (9 PM), `9 утра` (9 AM), `3 дня` (3 PM), `12 ночи` (12 AM)
//!
//! Default duration: if only start_time is found, end_time = start_time + 60min.
//! All times in minutes since midnight (0..1439).
//!
//! STRICT: Zero `.unwrap()`. No panics. All allocations caller-freed.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

// ═══════════════════════════════════════════════════════════════════════════════
// C-ABI RESULT STRUCT
// ═══════════════════════════════════════════════════════════════════════════════

/// Result of parsing a raw input string.
/// All heap-allocated fields must be freed by Dart via `ffi_free_parse_result`.
#[repr(C)]
pub struct CParseResult {
    /// Cleaned title with all tokens stripped. Caller must free.
    pub clean_title: *mut c_char,
    /// Start time in minutes since midnight. -1 if none parsed.
    pub start_time: i64,
    /// End time in minutes since midnight. -1 if none parsed.
    pub end_time: i64,
    /// Priority level: 0=Normal, 1=Important, 2=Very Important.
    pub priority: u8,
    /// Array of tag strings (each is *mut c_char). Caller must free each + the array.
    pub tags: *mut *mut c_char,
    /// Number of tags.
    pub tag_count: usize,
    /// Date token kind: 0 none, 1 offset-days, 2 weekday, 3 explicit.
    pub date_kind: u8,
    /// kind 1: days from today · kind 2: ISO weekday 1-7 · kind 3: year (0 = unspecified).
    pub date_a: i64,
    /// kind 3: month 1-12. Else -1.
    pub date_b: i64,
    /// kind 3: day 1-31. Else -1.
    pub date_c: i64,
}

// ═══════════════════════════════════════════════════════════════════════════════
// INTERNAL PARSED RESULT (safe Rust types)
// ═══════════════════════════════════════════════════════════════════════════════

struct ParsedInput {
    clean_title: String,
    start_time: Option<i64>,  // minutes since midnight
    end_time: Option<i64>,    // minutes since midnight
    priority: u8,
    tags: Vec<String>,
    date: Option<DateToken>,
}

/// A parsed calendar-date token. Resolution to a concrete day (timezone,
/// nearest-occurrence, year inference) happens on the Dart side.
#[derive(Debug, PartialEq, Clone, Copy)]
enum DateToken {
    /// Days from today: 0 = today, 1 = tomorrow, 2 = day after tomorrow.
    Offset(i64),
    /// ISO weekday 1 (Mon) ..= 7 (Sun), nearest occurrence including today.
    Weekday(i64),
    /// (year | 0 = unspecified, month 1-12, day 1-31).
    Explicit(i64, i64, i64),
}

// ═══════════════════════════════════════════════════════════════════════════════
// CORE PARSER
// ═══════════════════════════════════════════════════════════════════════════════

/// Parse a raw input string into structured tokens.
/// This is the hot path — called on every keystroke.
fn parse_input(raw: &str) -> ParsedInput {
    parse_input_opts(raw, true)
}

/// Parse with options. `extract_date_enabled = false` is the TARGETED mode: the
/// pill is already pinned to a specific day (day-view `C`/«+», mouse-«+»), so a
/// typed calendar date must NOT re-route the task. We skip date extraction — the
/// date words STAY in `clean_title` (zero lost input) and `date` is None — while
/// still parsing time (a time schedules WITHIN the pinned day), tags, priority.
fn parse_input_opts(raw: &str, extract_date_enabled: bool) -> ParsedInput {
    let mut text = raw.to_string();

    // ── Step 1: Priority ──────────────────────────────────────────────────────
    let priority = extract_priority(&mut text);

    // ── Step 2: Tags ──────────────────────────────────────────────────────────
    let tags = extract_tags(&mut text);

    // ── Step 3: Date BEFORE time ──────────────────────────────────────────────
    // A calendar date can wear a preposition that also opens a bare-hour time:
    // «на 12 июля» is July 12, but the time parser would grab «на 12» = 12:00
    // and orphan «июля». Claiming the date first settles it; the HH.MM-vs-DD.MM
    // ambiguity is handled locally in each parser, so order is otherwise safe.
    // Targeted mode leaves the date in place as ordinary title text.
    let date = if extract_date_enabled {
        extract_date(&mut text)
    } else {
        None
    };

    // ── Step 4: Time ──────────────────────────────────────────────────────────
    let (start_time, end_time) = extract_time(&mut text);

    // ── Step 5: Cleanup ───────────────────────────────────────────────────────
    let clean_title = normalize_whitespace(&text);

    ParsedInput {
        clean_title,
        start_time,
        end_time,
        priority,
        tags,
        date,
    }
}

/// Extract priority markers from text. Modifies text in-place.
/// `!!` → 2, `!` → 1, none → 0.
fn extract_priority(text: &mut String) -> u8 {
    // Check for `!!` first (greedy)
    if let Some(pos) = text.find("!!") {
        text.replace_range(pos..pos + 2, "");
        return 2;
    }
    // Then single `!` — but only standalone (not inside words like "don't")
    // We look for `!` that is either at the start/end or surrounded by whitespace
    if let Some(pos) = text.find('!') {
        // Ensure it's not inside a word (check neighbors)
        let before_ok = pos == 0 || text.as_bytes().get(pos - 1).map_or(true, |b| *b == b' ');
        let after_ok = pos + 1 >= text.len() || text.as_bytes().get(pos + 1).map_or(true, |b| *b == b' ');
        if before_ok || after_ok {
            text.replace_range(pos..pos + 1, "");
            return 1;
        }
    }
    0
}

/// Extract `#tag` tokens from text. Modifies text in-place.
/// `№` (RU layout Shift+3) is accepted as a sigil equivalent to `#`.
fn extract_tags(text: &mut String) -> Vec<String> {
    let mut tags = Vec::new();

    // Regex-free approach: find a sigil followed by word characters
    loop {
        let (sigil_pos, sigil_len) = match text
            .char_indices()
            .find(|(_, c)| *c == '#' || *c == '№')
        {
            Some((p, c)) => (p, c.len_utf8()),
            None => break,
        };

        // Must be at start or preceded by whitespace
        if sigil_pos > 0 {
            let prev_byte = text.as_bytes()[sigil_pos - 1];
            if prev_byte != b' ' && prev_byte != b'\t' && prev_byte != b'\n' {
                // Sigil is inside a word, skip
                break;
            }
        }

        // Collect the tag word (alphanumeric + underscore, supports Unicode)
        let tag_start = sigil_pos + sigil_len;
        let rest = &text[tag_start..];
        let tag_end_offset = rest
            .char_indices()
            .take_while(|(_, c)| c.is_alphanumeric() || *c == '_')
            .last()
            .map(|(i, c)| i + c.len_utf8())
            .unwrap_or(0);
        
        if tag_end_offset == 0 {
            // Lone sigil with no word after it — leave it
            break;
        }

        let tag = rest[..tag_end_offset].to_string();
        tags.push(tag);

        // Remove sigil+tag from text
        text.replace_range(sigil_pos..tag_start + tag_end_offset, "");
    }
    
    tags
}

/// Extract time patterns from text. Modifies text in-place.
/// Returns (start_minutes, end_minutes) or (None, None).
fn extract_time(text: &mut String) -> (Option<i64>, Option<i64>) {
    // Try patterns in order of specificity (most specific first)

    // ── Pattern 0: Russian "с N до N" (from...to) ──
    if let Some(result) = try_extract_russian_from_to(text) {
        return result;
    }

    // ── Pattern 0.5: English "5pm" / "at 5" / "5-6pm" / noon / midnight ──
    // Must run before the digital range/colon parsers: "5-6pm" would otherwise
    // be eaten as 05:00-06:00 with a stray "pm" left in the title.
    if let Some(result) = try_extract_english_time(text) {
        return apply_default_duration_if_open(result);
    }

    // ── Pattern 1: HH:MM-HH:MM or HH.MM-HH.MM or HH-HH (time range) ──
    if let Some(result) = try_extract_time_range(text) {
        return result;
    }
    
    // ── Pattern 2: HH:MM or HH.MM (exact time) ──
    if let Some(result) = try_extract_colon_time(text) {
        return apply_default_duration(result);
    }
    
    // ── Pattern 3: Russian "N вечера/утра/дня/ночи" ──
    if let Some(result) = try_extract_russian_period(text) {
        return apply_default_duration(result);
    }
    
    // ── Pattern 4: Russian "на N" / "в N" / "в N часов/часа" ──
    if let Some(result) = try_extract_russian_at(text) {
        return apply_default_duration(result);
    }
    
    (None, None)
}

/// Parse a bare hour (1 or 2 ASCII digit(s), 0-23) starting at `pos` in bytes.
/// Returns (hour_value, bytes_consumed). Does NOT accept HH:MM here — that's
/// handled by try_parse_hhmm_at. We accept only plain digits.
fn try_parse_bare_hour_at(bytes: &[u8], pos: usize) -> Option<(u32, usize)> {
    let len = bytes.len();
    if pos >= len || !bytes[pos].is_ascii_digit() {
        return None;
    }
    let mut end = pos + 1;
    if end < len && bytes[end].is_ascii_digit() {
        end += 1;
    }
    // Make sure we don't consume a colon/dot time (leave that to hhmm parser)
    if end < len && (bytes[end] == b':' || bytes[end] == b'.') {
        return None;
    }
    let s = std::str::from_utf8(&bytes[pos..end]).ok()?;
    let h: u32 = s.parse().ok()?;
    if h > 23 {
        return None;
    }
    Some((h, end - pos))
}

/// Try parse either HH:MM/HH.MM (full) or bare HH (shorthand).
/// Returns (minutes_since_midnight, bytes_consumed).
fn try_parse_any_time_at(bytes: &[u8], pos: usize) -> Option<(i64, usize)> {
    // Full HH:MM / HH.MM first
    if let Some(r) = try_parse_hhmm_at(bytes, pos) {
        return Some(r);
    }
    // Bare hour
    if let Some((h, c)) = try_parse_bare_hour_at(bytes, pos) {
        return Some((h as i64 * 60, c));
    }
    None
}

/// Russian "с [time] до [time]" — e.g. "с 17 до 21", "с 9:30 до 11".
fn try_extract_russian_from_to(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    let lower = text.to_lowercase();
    let from_markers = ["с ", "от "];
    let to_markers = [" до ", " по "];

    for from_m in &from_markers {
        let from_mlen = from_m.len();
        let mut search = 0usize;
        while let Some(rel) = lower[search..].find(from_m) {
            let from_pos = search + rel;
            // word boundary before
            let before_ok = from_pos == 0
                || lower.as_bytes().get(from_pos - 1).map_or(true, |b| b.is_ascii_whitespace());
            if !before_ok {
                search = from_pos + from_mlen;
                continue;
            }
            let after_from = from_pos + from_mlen;
            let bytes = lower.as_bytes();
            if let Some((start_mins, consumed_start)) = try_parse_any_time_at(bytes, after_from) {
                // look for "до" / "по" after start
                let after_start_pos = after_from + consumed_start;
                let rest_lower = &lower[after_start_pos..];
                for to_m in &to_markers {
                    if let Some(to_rel) = rest_lower.find(to_m) {
                        let to_pos = after_start_pos + to_rel;
                        let after_to = to_pos + to_m.len();
                        if let Some((end_mins, consumed_end)) = try_parse_any_time_at(bytes, after_to) {
                            let total_end = after_to + consumed_end;
                            text.replace_range(from_pos..total_end.min(text.len()), "");
                            // «с 23 до 1» crosses midnight → end lands on the next day
                            let end_adj = if end_mins <= start_mins { end_mins + 1440 } else { end_mins };
                            return Some((Some(start_mins), Some(end_adj)));
                        }
                    }
                }
            }
            search = from_pos + from_mlen;
        }
    }
    None
}

/// Try to extract time ranges:
///   HH:MM-HH:MM, HH.MM-HH.MM (full)
///   HH:MM-HH, HH-HH:MM, HH-HH (shorthand)
fn try_extract_time_range(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    let bytes = text.as_bytes();
    let len = bytes.len();

    for i in 0..len {
        // Must start with a digit
        if !bytes[i].is_ascii_digit() {
            continue;
        }
        // Must be preceded by whitespace or start-of-string (avoid e.g. "note5-6")
        let before_ok = i == 0 || bytes[i - 1].is_ascii_whitespace();
        if !before_ok {
            continue;
        }
        if let Some((start_mins, consumed_start)) = try_parse_any_time_at(bytes, i) {
            let after_start = i + consumed_start;
            if after_start < len && bytes[after_start] == b'-' {
                let dash_next = after_start + 1;
                // Ensure it's a digit after the dash (not a negative sign for something else)
                if dash_next < len && bytes[dash_next].is_ascii_digit() {
                    if let Some((end_mins, consumed_end)) = try_parse_any_time_at(bytes, dash_next) {
                        let total_consumed = consumed_start + 1 + consumed_end;
                        // end at/before start = crosses midnight («23-1» → 23:00→01:00 next day)
                        let end_adj = if end_mins <= start_mins { end_mins + 1440 } else { end_mins };
                        text.replace_range(i..i + total_consumed, "");
                        return Some((Some(start_mins), Some(end_adj)));
                    }
                }
            }
        }
    }
    None
}

/// Try to extract HH:MM or HH.MM.
fn try_extract_colon_time(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    let bytes = text.as_bytes();
    let len = bytes.len();
    
    for i in 0..len {
        if let Some((mins, consumed)) = try_parse_hhmm_at(bytes, i) {
            // Make sure this isn't part of a larger number
            let before_ok = i == 0 || !bytes[i - 1].is_ascii_digit();
            let after_pos = i + consumed;
            let after_ok = after_pos >= len || !bytes[after_pos].is_ascii_digit();
            
            if before_ok && after_ok {
                text.replace_range(i..i + consumed, "");
                return Some((Some(mins), None));
            }
        }
    }
    None
}

/// Try to parse HH:MM or HH.MM at a specific byte position.
/// Returns (minutes_since_midnight, bytes_consumed).
fn try_parse_hhmm_at(bytes: &[u8], pos: usize) -> Option<(i64, usize)> {
    let len = bytes.len();
    
    // Try H:MM (e.g., "9:30") — 4 bytes
    // Try HH:MM (e.g., "14:30") — 5 bytes
    // Try H.MM — 4 bytes
    // Try HH.MM — 5 bytes
    
    // First, collect hour digits (1 or 2)
    if pos >= len || !bytes[pos].is_ascii_digit() {
        return None;
    }
    
    let mut hour_end = pos + 1;
    if hour_end < len && bytes[hour_end].is_ascii_digit() {
        hour_end += 1;
    }
    
    let hour_str = std::str::from_utf8(&bytes[pos..hour_end]).ok()?;
    let hour: u32 = hour_str.parse().ok()?;
    if hour > 23 {
        return None;
    }
    
    // Check separator
    if hour_end >= len {
        return None;
    }
    let sep = bytes[hour_end];
    if sep != b':' && sep != b'.' {
        return None;
    }
    
    // Must have exactly 2 minute digits
    let min_start = hour_end + 1;
    if min_start + 2 > len {
        return None;
    }
    if !bytes[min_start].is_ascii_digit() || !bytes[min_start + 1].is_ascii_digit() {
        return None;
    }
    
    let min_str = std::str::from_utf8(&bytes[min_start..min_start + 2]).ok()?;
    let min: u32 = min_str.parse().ok()?;
    if min > 59 {
        return None;
    }

    // Dotted form that reads as a calendar date (DD.MM: month 1-12) belongs to
    // the date parser — «15.07» is July 15, but «12.30» / «14.00» stay times.
    if sep == b'.' && (1..=12).contains(&min) && (1..=31).contains(&hour) {
        return None;
    }

    let total_consumed = (min_start + 2) - pos;
    let minutes = (hour * 60 + min) as i64;
    Some((minutes, total_consumed))
}

/// Try to extract Russian period time: "9 вечера", "9 утра", "3 дня", "12 ночи"
fn try_extract_russian_period(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    // UTF-8 aware: we work with chars/string slices
    let lower = text.to_lowercase();
    
    let period_words = [
        ("утра", PeriodKind::Am),
        ("утро", PeriodKind::Am),
        ("вечера", PeriodKind::Pm),
        ("вечер", PeriodKind::Pm),
        ("дня", PeriodKind::Afternoon),
        ("день", PeriodKind::Afternoon),
        ("ночи", PeriodKind::Night),
        ("ночь", PeriodKind::Night),
    ];
    
    for (word, kind) in &period_words {
        if let Some(word_pos) = lower.find(word) {
            // Look backward for a number
            let before = &lower[..word_pos].trim_end();
            if let Some(num_result) = extract_trailing_number(before) {
                // «через 3 дня» is a duration (3 days), not 3 PM — the date
                // parser owns it.
                if before[..num_result.start].trim_end().ends_with("через") {
                    continue;
                }
                let hour = adjust_hour_for_period(num_result.value, kind);
                if let Some(h) = hour {
                    let mins = h as i64 * 60;
                    // Remove the matched portion from original text
                    let remove_start = word_pos - (before.len() - num_result.start);
                    let remove_end_byte = find_byte_pos_after(text, word_pos, word);
                    text.replace_range(remove_start..remove_end_byte, "");
                    return Some((Some(mins), None));
                }
            }
        }
    }
    
    None
}

/// Find byte position after a word match (accounts for case differences in original)
fn find_byte_pos_after(text: &str, lower_pos: usize, word: &str) -> usize {
    // Since we matched on lowercase, the byte positions may differ
    // But for Cyrillic, each char is 2 bytes in both cases, so positions align
    let word_byte_len = word.len();
    let end = lower_pos + word_byte_len;
    end.min(text.len())
}

#[derive(Clone, Copy)]
enum PeriodKind {
    Am,
    Pm,
    Afternoon,
    Night,
}

struct NumberResult {
    value: u32,
    start: usize, // byte offset within the trimmed "before" string
}

fn extract_trailing_number(s: &str) -> Option<NumberResult> {
    let s = s.trim_end();
    if s.is_empty() {
        return None;
    }
    
    // Walk backward to find digits
    let bytes = s.as_bytes();
    let mut end = bytes.len();
    let mut start = end;
    
    while start > 0 && bytes[start - 1].is_ascii_digit() {
        start -= 1;
    }
    
    if start < end {
        let num_str = std::str::from_utf8(&bytes[start..end]).ok()?;
        let value: u32 = num_str.parse().ok()?;
        return Some(NumberResult { value, start });
    }
    
    // Try word matching at the end
    let words_full = [
        ("двадцать четыре", 24), ("двадцать три", 23),
        ("двадцать два", 22), ("двадцать один", 21),
        ("одиннадцать", 11), ("двенадцать", 12), ("тринадцать", 13), ("четырнадцать", 14),
        ("пятнадцать", 15), ("шестнадцать", 16), ("семнадцать", 17), ("восемнадцать", 18),
        ("девятнадцать", 19), ("двадцать", 20),
        ("один", 1), ("два", 2), ("две", 2), ("три", 3), ("четыре", 4), ("пять", 5),
        ("шесть", 6), ("семь", 7), ("восемь", 8), ("девять", 9), ("десять", 10),
        ("час", 1),
    ];
    
    for &(w, val) in &words_full {
        if s.ends_with(w) {
            let start_idx = s.len() - w.len();
            // boundary check
            if start_idx == 0 || bytes[start_idx - 1] == b' ' || bytes[start_idx - 1] == b'\t' {
                return Some(NumberResult { value: val, start: start_idx });
            }
        }
    }
    
    None
}

fn adjust_hour_for_period(hour: u32, kind: &PeriodKind) -> Option<u32> {
    if hour == 0 || hour > 12 {
        return None;
    }
    
    match kind {
        PeriodKind::Am => {
            // "утра": 1-12 → 1-11, 12 → 0
            Some(if hour == 12 { 0 } else { hour })
        }
        PeriodKind::Pm => {
            // "вечера": 1-11 → 13-23, 12 → 12
            if hour <= 4 {
                // "4 вечера" → 16:00, but "5 вечера" → 17:00
                Some(hour + 12)
            } else if hour <= 11 {
                Some(hour + 12)
            } else {
                Some(12)
            }
        }
        PeriodKind::Afternoon => {
            // "дня": 1-4 → 13-16, 12 → 12
            if hour <= 4 {
                Some(hour + 12)
            } else if hour == 12 {
                Some(12)
            } else {
                None
            }
        }
        PeriodKind::Night => {
            // "ночи": 12 → 0, 1-4 → 1-4
            if hour == 12 { Some(0) } else if hour <= 4 { Some(hour) } else { None }
        }
    }
}

/// Try to extract Russian "на N" / "в N" / "в N часов/часа/час" patterns.
/// Uses word-boundary check: "в" must be preceded by start-of-string or whitespace,
/// so "вайбер" or "вечер" won't accidentally match.
fn try_extract_russian_at(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    let lower = text.to_lowercase();

    // ── Pass 1: Try prefixed patterns "на N" / "в N [часов|часа|час]" ──────────
    // "с " is intentionally excluded — it's ambiguous (means "from" not "at")
    let prefixes: &[&str] = &["на ", "в "];

    for prefix in prefixes {
        let plen = prefix.len();
        let mut search_start = 0usize;

        while let Some(rel_pos) = lower[search_start..].find(prefix) {
            let pref_pos = search_start + rel_pos;

            // Word-boundary check: "в" must be at start or after whitespace
            let before_ok = pref_pos == 0
                || lower.as_bytes().get(pref_pos - 1).map_or(true, |b| b.is_ascii_whitespace());

            if !before_ok {
                search_start = pref_pos + plen;
                continue;
            }

            let after_prefix = pref_pos + plen;
            let rest = &lower[after_prefix..];

            if let Some((hour, consumed_len)) = parse_russian_number_at_start(rest) {
                if hour > 23 {
                    search_start = pref_pos + plen;
                    continue;
                }

                // Check for optional "часов/часа/час" suffix
                let remaining_after_num = rest[consumed_len..].trim_start();
                let mut extra_consumed = 0usize;
                for suffix in &["часов", "часа", "час"] {
                    if remaining_after_num.starts_with(suffix) {
                        let whitespace_len = rest[consumed_len..].len() - remaining_after_num.len();
                        extra_consumed = whitespace_len + suffix.len();
                        break;
                    }
                }

                let total_remove = plen + consumed_len + extra_consumed;
                let remove_end = (pref_pos + total_remove).min(text.len());
                text.replace_range(pref_pos..remove_end, "");

                let mins = hour as i64 * 60;
                return Some((Some(mins), None));
            }

            search_start = pref_pos + plen;
        }
    }

    // ── Pass 2: Bare "N часов/часа/час" without a preposition ───────────────
    // e.g. "встреча 9 часов" → 09:00
    let bare_suffixes: &[&str] = &["часов", "часа", "час"];
    for suffix in bare_suffixes {
        if let Some(suf_pos) = lower.find(suffix) {
            // Look backward for a trailing decimal number before the suffix
            let before_suf = lower[..suf_pos].trim_end();
            // Find the last run of ASCII digits in `before_suf`
            let num_start = before_suf
                .char_indices()
                .filter(|&(_, c)| !c.is_ascii_digit())
                .last()
                .map(|(p, c)| p + c.len_utf8())
                .unwrap_or(0);
            let num_str = &before_suf[num_start..];
            if !num_str.is_empty() {
                if let Ok(hour) = num_str.parse::<u32>() {
                    if hour <= 23 {
                        // byte position of num_start in original text (lower is same len as text for ASCII)
                        let remove_start = num_start;
                        let remove_end = (suf_pos + suffix.len()).min(text.len());
                        if remove_start < remove_end {
                            text.replace_range(remove_start..remove_end, "");
                        }
                        let mins = hour as i64 * 60;
                        return Some((Some(mins), None));
                    }
                }
            }
        }
    }

    None
}

// ─────────────────────────────────────────────────────────────────────────────
// English time forms: "5pm", "9 am", "5:30pm", "at 5", "5-6pm", noon/midnight
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
enum Meridiem { Am, Pm }

impl Meridiem {
    fn opposite(self) -> Self {
        match self { Meridiem::Am => Meridiem::Pm, Meridiem::Pm => Meridiem::Am }
    }
}

/// Parse "am"/"pm" at `pos` (optional leading spaces), case-insensitive.
/// Returns (meridiem, bytes consumed incl. the spaces). Word boundary after —
/// "5 among" must not read as 5am.
fn try_parse_meridiem_at(bytes: &[u8], pos: usize) -> Option<(Meridiem, usize)> {
    let len = bytes.len();
    let mut p = pos;
    while p < len && bytes[p] == b' ' { p += 1; }
    if p + 2 > len { return None; }
    let mer = match (bytes[p] | 32, bytes[p + 1] | 32) {
        (b'a', b'm') => Meridiem::Am,
        (b'p', b'm') => Meridiem::Pm,
        _ => return None,
    };
    let after = p + 2;
    if after < len && (bytes[after].is_ascii_alphanumeric() || bytes[after] == b'_') {
        return None;
    }
    Some((mer, after - pos))
}

/// 12-hour minutes + meridiem → 24-hour minutes. Rejects hours outside 1-12.
fn resolve_meridiem(mins: i64, mer: Meridiem) -> Option<i64> {
    let (h, m) = (mins / 60, mins % 60);
    if h == 0 || h > 12 { return None; }
    let h24 = match mer {
        Meridiem::Am => if h == 12 { 0 } else { h },
        Meridiem::Pm => if h == 12 { 12 } else { h + 12 },
    };
    Some(h24 * 60 + m)
}

/// Like apply_default_duration, but leaves explicit ranges untouched.
fn apply_default_duration_if_open(r: (Option<i64>, Option<i64>)) -> (Option<i64>, Option<i64>) {
    match r {
        (Some(s), None) => apply_default_duration((Some(s), None)),
        other => other,
    }
}

/// English pass, in order: "from X to Y" → time-with-meridiem (single or
/// range) → "at N" → noon/midnight. from-to must run first: the meridiem
/// scan would otherwise strip the "5pm" out of "from 9 to 5pm".
fn try_extract_english_time(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    if let Some(r) = try_extract_english_from_to(text) {
        return Some(r);
    }
    if let Some(r) = try_extract_meridiem_time(text) {
        return Some(r);
    }
    if let Some(r) = try_extract_english_at(text) {
        return Some(r);
    }
    try_extract_noon_midnight(text)
}

/// "from X to Y" — the English «с X до Y». Bare hours stay literal (as in
/// the Russian form); a meridiem on either side colors the range by the same
/// rules as dash ranges. End at/before start crosses midnight.
fn try_extract_english_from_to(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    let lower = text.to_lowercase();
    let bytes = lower.as_bytes();
    let marker = "from ";
    let mut search = 0usize;

    while let Some(rel) = lower[search..].find(marker) {
        let pos = search + rel;
        let before_ok = pos == 0
            || bytes.get(pos - 1).is_none_or(|b| b.is_ascii_whitespace());
        if !before_ok {
            search = pos + marker.len();
            continue;
        }
        let t1_pos = pos + marker.len();
        if let Some((t1, c1)) = try_parse_any_time_at(bytes, t1_pos) {
            let after_t1 = t1_pos + c1;
            let mer1 = try_parse_meridiem_at(bytes, after_t1);
            let after_m1 = after_t1 + mer1.map_or(0, |(_, c)| c);
            const TO: &str = " to ";
            if lower[after_m1..].starts_with(TO) {
                let t2_pos = after_m1 + TO.len();
                if let Some((t2, c2)) = try_parse_any_time_at(bytes, t2_pos) {
                    let after_t2 = t2_pos + c2;
                    let mer2 = try_parse_meridiem_at(bytes, after_t2);
                    let after_m2 = after_t2 + mer2.map_or(0, |(_, c)| c);
                    let resolved = match (mer1, mer2) {
                        (None, None) => {
                            Some((t1, if t2 <= t1 { t2 + 1440 } else { t2 }))
                        }
                        _ => resolve_meridiem_range(
                            t1, mer1.map(|(m, _)| m), t2, mer2.map(|(m, _)| m)),
                    };
                    if let Some((s, e)) = resolved {
                        text.replace_range(pos..after_m2.min(text.len()), "");
                        return Some((Some(s), Some(e)));
                    }
                }
            }
        }
        search = pos + marker.len();
    }
    None
}

/// A time token being stripped drags a preceding "at " out with it —
/// "gym at 6am" must not leave "gym at" behind.
fn sweep_at_prefix(lower: &str, pos: usize) -> usize {
    let head = &lower[..pos];
    if head.ends_with("at ") {
        let p = pos - 3;
        if p == 0 || lower.as_bytes().get(p - 1).is_none_or(|b| b.is_ascii_whitespace()) {
            return p;
        }
    }
    pos
}

/// `H[:MM][am|pm]` alone or as `A-B` where at least one side carries am/pm.
/// A meridiem on one side colors the other: "5-6pm" → 17:00–18:00, but
/// "11-1pm" keeps 11:00 (the pm start would land past the end).
fn try_extract_meridiem_time(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    let lower = text.to_lowercase();
    let bytes = lower.as_bytes();
    let len = bytes.len();

    for i in 0..len {
        if !bytes[i].is_ascii_digit() { continue; }
        if i > 0 && !bytes[i - 1].is_ascii_whitespace() { continue; }
        let Some((t1, c1)) = try_parse_any_time_at(bytes, i) else { continue };
        let after_t1 = i + c1;
        let mer1 = try_parse_meridiem_at(bytes, after_t1);
        let after_m1 = after_t1 + mer1.map_or(0, |(_, c)| c);

        // ── Range: dash directly after the first token ──
        if after_m1 < len && bytes[after_m1] == b'-' {
            let t2_pos = after_m1 + 1;
            if t2_pos < len && bytes[t2_pos].is_ascii_digit() {
                if let Some((t2, c2)) = try_parse_any_time_at(bytes, t2_pos) {
                    let after_t2 = t2_pos + c2;
                    let mer2 = try_parse_meridiem_at(bytes, after_t2);
                    let after_m2 = after_t2 + mer2.map_or(0, |(_, c)| c);
                    if mer1.is_some() || mer2.is_some() {
                        if let Some((s, e)) = resolve_meridiem_range(
                            t1, mer1.map(|(m, _)| m), t2, mer2.map(|(m, _)| m)) {
                            let from = sweep_at_prefix(&lower, i);
                            text.replace_range(from..after_m2.min(text.len()), "");
                            return Some((Some(s), Some(e)));
                        }
                    }
                }
            }
        }

        // ── Single token with meridiem ──
        if let Some((m, _)) = mer1 {
            if let Some(resolved) = resolve_meridiem(t1, m) {
                let from = sweep_at_prefix(&lower, i);
                text.replace_range(from..after_m1.min(text.len()), "");
                return Some((Some(resolved), None));
            }
        }
    }
    None
}

/// Resolve an A-B range where at least one side has a meridiem.
fn resolve_meridiem_range(
    t1: i64, mer1: Option<Meridiem>, t2: i64, mer2: Option<Meridiem>,
) -> Option<(i64, i64)> {
    match (mer1, mer2) {
        (Some(m1), Some(m2)) => {
            let s = resolve_meridiem(t1, m1)?;
            let mut e = resolve_meridiem(t2, m2)?;
            if e <= s { e += 1440; }
            Some((s, e))
        }
        (None, Some(m2)) => {
            // "5-6pm" / "11-1pm": end is fixed; start takes the same meridiem
            // unless that would put it past the end — then it stays as typed.
            let e = resolve_meridiem(t2, m2)?;
            let s = match resolve_meridiem(t1, m2) {
                Some(c) if c <= e => c,
                _ if t1 <= e => t1,
                _ => resolve_meridiem(t1, m2.opposite()).filter(|c| *c <= e)?,
            };
            Some((s, e))
        }
        (Some(m1), None) => {
            // "5pm-7" / "11am-1": start is fixed; end tries the same meridiem,
            // then the opposite, then as typed; last resort crosses midnight.
            let s = resolve_meridiem(t1, m1)?;
            let e = [resolve_meridiem(t2, m1), resolve_meridiem(t2, m1.opposite()), Some(t2)]
                .into_iter()
                .flatten()
                .find(|c| *c > s)
                .unwrap_or(t2 + 1440);
            Some((s, e))
        }
        (None, None) => None,
    }
}

/// `at H[:MM]` — 24h or 12h. A bare small hour leans afternoon (1..=7 → PM):
/// "call at 5" means 17:00 to a human; 8..=23 stay literal. An explicit
/// meridiem was already handled by try_extract_meridiem_time.
fn try_extract_english_at(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    let lower = text.to_lowercase();
    let bytes = lower.as_bytes();
    let prefix = "at ";
    let mut search = 0usize;

    while let Some(rel) = lower[search..].find(prefix) {
        let pos = search + rel;
        let before_ok = pos == 0
            || bytes.get(pos - 1).is_none_or(|b| b.is_ascii_whitespace());
        if !before_ok {
            search = pos + prefix.len();
            continue;
        }
        let t_pos = pos + prefix.len();
        if let Some((t, c)) = try_parse_any_time_at(bytes, t_pos) {
            let h = t / 60;
            let resolved = if (1..=7).contains(&h) { t + 720 } else { t };
            text.replace_range(pos..(t_pos + c).min(text.len()), "");
            return Some((Some(resolved), None));
        }
        search = pos + prefix.len();
    }
    None
}

/// `noon` → 12:00, `midnight` → 00:00; a preceding "at " is swept with it.
fn try_extract_noon_midnight(text: &mut String) -> Option<(Option<i64>, Option<i64>)> {
    let lower = text.to_lowercase();
    // «полночь»/«полдень» mirror midnight/noon; a leading «at »/«в » is swept in.
    for (word, mins) in [
        ("midnight", 0i64), ("noon", 720i64),
        ("полночь", 0i64), ("полдень", 720i64),
    ] {
        let Some(pos) = find_word(&lower, word) else { continue };
        let mut start = pos;
        let head = &lower[..pos];
        for p in &["at ", "в "] {
            if head.ends_with(p) {
                let cand = pos - p.len();
                if cand == 0
                    || lower.as_bytes().get(cand - 1).is_none_or(|b| b.is_ascii_whitespace())
                {
                    start = cand;
                }
                break;
            }
        }
        text.replace_range(start..pos + word.len(), "");
        return Some((Some(mins), None));
    }
    None
}

fn parse_russian_number_at_start(s: &str) -> Option<(u32, usize)> {
    // Digits
    let bytes = s.as_bytes();
    let mut num_end = 0;
    for (i, b) in bytes.iter().enumerate() {
        if b.is_ascii_digit() {
            num_end = i + 1;
        } else {
            break;
        }
    }
    if num_end > 0 {
        if let Ok(n) = s[..num_end].parse::<u32>() {
            return Some((n, num_end));
        }
    }
    
    // Words
    let words_full = [
        ("двадцать четыре", 24), ("двадцать три", 23),
        ("двадцать два", 22), ("двадцать один", 21),
        ("одиннадцать", 11), ("двенадцать", 12), ("тринадцать", 13), ("четырнадцать", 14),
        ("пятнадцать", 15), ("шестнадцать", 16), ("семнадцать", 17), ("восемнадцать", 18),
        ("девятнадцать", 19), ("двадцать", 20),
        ("один", 1), ("два", 2), ("две", 2), ("три", 3), ("четыре", 4), ("пять", 5),
        ("шесть", 6), ("семь", 7), ("восемь", 8), ("девять", 9), ("десять", 10),
        ("час", 1),
    ];
    
    for &(w, val) in &words_full {
        if s.starts_with(w) {
            let after_len = w.len();
            // boundary check
            if after_len >= s.len() || bytes[after_len] == b' ' || bytes[after_len] == b'\t' {
                return Some((val, after_len));
            }
        }
    }
    None
}

// ═══════════════════════════════════════════════════════════════════════════════
// DATE EXTRACTION
// ═══════════════════════════════════════════════════════════════════════════════

fn is_boundary_before(bytes: &[u8], pos: usize) -> bool {
    pos == 0 || bytes[pos - 1].is_ascii_whitespace()
}

/// True when the char at `end` can close a word: end-of-string, whitespace,
/// or light punctuation. Rejects alphanumerics («завтрак» ≠ «завтра»).
fn is_boundary_after(s: &str, end: usize) -> bool {
    match s[end..].chars().next() {
        None => true,
        Some(c) => c.is_whitespace() || matches!(c, ',' | '.' | '!' | '?' | ';' | ')' | ':'),
    }
}

/// Find `word` in `lower` as a standalone word (whitespace-bounded).
fn find_word(lower: &str, word: &str) -> Option<usize> {
    let mut start = 0usize;
    while let Some(rel) = lower.get(start..).and_then(|s| s.find(word)) {
        let pos = start + rel;
        let end = pos + word.len();
        if is_boundary_before(lower.as_bytes(), pos) && is_boundary_after(lower, end) {
            return Some(pos);
        }
        start = end;
    }
    None
}

/// Extract a calendar-date token. Modifies text in-place. Patterns by
/// specificity: DD.MM(.YYYY) → «15 июля»/«jul 15» → сегодня/завтра/послезавтра
/// → weekday («в пятницу», «пт», friday).
fn extract_date(text: &mut String) -> Option<DateToken> {
    if let Some(t) = try_extract_numeric_date(text) {
        return Some(t);
    }
    if let Some(t) = try_extract_month_name_date(text) {
        return Some(t);
    }
    if let Some(t) = try_extract_in_days(text) {
        return Some(t);
    }
    if let Some(t) = try_extract_relative_date(text) {
        return Some(t);
    }
    try_extract_weekday(text)
}

/// «через N дней/недель», «через неделю», "in N days/weeks", "in a week".
fn try_extract_in_days(text: &mut String) -> Option<DateToken> {
    let lower = text.to_lowercase();
    for marker in &["через", "in"] {
        let Some(pos) = find_word(&lower, marker) else { continue };
        let after = pos + marker.len();
        let rest = &lower[after..];
        let ws = rest.len() - rest.trim_start().len();
        if ws == 0 {
            continue;
        }
        let num_start = after + ws;
        let tail = &lower[num_start..];

        // Number: digits, RU number words, or EN "a" (= 1).
        let (n, num_len) = if let Some((v, l)) = parse_russian_number_at_start(tail) {
            (v as i64, l)
        } else if tail.starts_with("a ") || tail == "a" {
            (1, 1)
        } else if tail.starts_with("неделю") {
            (1, 0) // «через неделю» — unit carries the 1
        } else {
            continue;
        };
        if n == 0 || n > 365 {
            continue;
        }

        let unit_rest = &lower[num_start + num_len..];
        let unit_ws = unit_rest.len() - unit_rest.trim_start().len();
        let unit_start = num_start + num_len + unit_ws;
        let unit_tail = &lower[unit_start..];

        let day_units = ["дней", "дня", "день", "days", "day"];
        let week_units = ["недель", "недели", "неделю", "weeks", "week"];
        let mut matched: Option<(usize, i64)> = None;
        for u in &day_units {
            if unit_tail.starts_with(u) && is_boundary_after(&lower, unit_start + u.len()) {
                matched = Some((u.len(), n));
                break;
            }
        }
        if matched.is_none() {
            for u in &week_units {
                if unit_tail.starts_with(u) && is_boundary_after(&lower, unit_start + u.len()) {
                    matched = Some((u.len(), n * 7));
                    break;
                }
            }
        }
        let Some((unit_len, days)) = matched else { continue };
        text.replace_range(pos..unit_start + unit_len, "");
        return Some(DateToken::Offset(days));
    }
    None
}

fn digits_val(bytes: &[u8], a: usize, b: usize) -> Option<i64> {
    std::str::from_utf8(&bytes[a..b]).ok()?.parse::<i64>().ok()
}

/// DD.MM, DD.M or DD.MM.YYYY (day 1-31, month 1-12; year exactly 4 digits).
fn try_extract_numeric_date(text: &mut String) -> Option<DateToken> {
    let bytes: Vec<u8> = text.bytes().collect();
    for i in 0..bytes.len() {
        if !bytes[i].is_ascii_digit() || !is_boundary_before(&bytes, i) {
            continue;
        }
        if let Some((day, month, year, consumed)) = parse_numeric_date_at(&bytes, i) {
            let end = i + consumed;
            if is_boundary_after(text, end) {
                let lower = text.to_lowercase();
                let from = consume_date_prefix(&lower, i);
                text.replace_range(from..end, "");
                return Some(DateToken::Explicit(year, month, day));
            }
        }
    }
    None
}

fn parse_numeric_date_at(bytes: &[u8], pos: usize) -> Option<(i64, i64, i64, usize)> {
    let len = bytes.len();
    let mut p = pos;
    while p < len && bytes[p].is_ascii_digit() {
        p += 1;
    }
    if p - pos == 0 || p - pos > 2 {
        return None;
    }
    let day = digits_val(bytes, pos, p)?;
    if !(1..=31).contains(&day) {
        return None;
    }
    if p >= len || bytes[p] != b'.' {
        return None;
    }
    p += 1;
    let mon_start = p;
    while p < len && bytes[p].is_ascii_digit() {
        p += 1;
    }
    if p - mon_start == 0 || p - mon_start > 2 {
        return None;
    }
    let month = digits_val(bytes, mon_start, p)?;
    if !(1..=12).contains(&month) {
        return None;
    }
    // Optional .YYYY — anything else after a second dot+digit is ambiguous.
    if p < len && bytes[p] == b'.' {
        let y_start = p + 1;
        let mut q = y_start;
        while q < len && bytes[q].is_ascii_digit() {
            q += 1;
        }
        if q - y_start == 4 {
            let year = digits_val(bytes, y_start, q)?;
            return Some((day, month, year, q - pos));
        }
        if q > y_start {
            return None;
        }
    }
    Some((day, month, 0, p - pos))
}

const MONTH_NAMES: &[(&str, i64)] = &[
    ("января", 1), ("февраля", 2), ("марта", 3), ("апреля", 4), ("мая", 5), ("июня", 6),
    ("июля", 7), ("августа", 8), ("сентября", 9), ("октября", 10), ("ноября", 11), ("декабря", 12),
    ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("june", 6), ("july", 7),
    ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12),
    ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("may", 5), ("jun", 6), ("jul", 7),
    ("aug", 8), ("sep", 9), ("oct", 10), ("nov", 11), ("dec", 12),
];

/// A date can be introduced by a preposition that belongs to it: «на 12 июля»,
/// «в 15.07», «on jul 12». Extend the match leftward over that word so it does
/// not survive in the title. Returns the (possibly earlier) start byte.
fn consume_date_prefix(lower: &str, start: usize) -> usize {
    for p in &["на ", "в ", "on "] {
        if start >= p.len() && lower[..start].ends_with(p) {
            let cand = start - p.len();
            if cand == 0 || lower.as_bytes()[cand - 1].is_ascii_whitespace() {
                return cand;
            }
        }
    }
    start
}

/// «15 июля» / «jul 15» / «15 jul». A month name alone is not a date.
fn try_extract_month_name_date(text: &mut String) -> Option<DateToken> {
    let lower = text.to_lowercase();
    for &(name, month) in MONTH_NAMES {
        let Some(pos) = find_word(&lower, name) else { continue };
        let end = pos + name.len();

        // Number before: «15 июля»
        let before = lower[..pos].trim_end();
        let gap_is_space = lower[before.len()..pos].chars().all(char::is_whitespace);
        if gap_is_space {
            if let Some(num) = extract_trailing_number(before) {
                if (1..=31).contains(&(num.value as i64))
                    && is_boundary_before(lower.as_bytes(), num.start)
                    && lower.as_bytes().get(num.start).map_or(false, |b| b.is_ascii_digit())
                {
                    let from = consume_date_prefix(&lower, num.start);
                    text.replace_range(from..end, "");
                    return Some(DateToken::Explicit(0, month, num.value as i64));
                }
            }
        }

        // Number after: «jul 15»
        let rest = &lower[end..];
        let ws = rest.len() - rest.trim_start().len();
        if ws > 0 {
            let num_start = end + ws;
            let bytes = lower.as_bytes();
            let mut q = num_start;
            while q < bytes.len() && bytes[q].is_ascii_digit() {
                q += 1;
            }
            if q > num_start && q - num_start <= 2 && is_boundary_after(&lower, q) {
                if let Some(day) = digits_val(bytes, num_start, q) {
                    if (1..=31).contains(&day) {
                        let from = consume_date_prefix(&lower, pos);
                        text.replace_range(from..q, "");
                        return Some(DateToken::Explicit(0, month, day));
                    }
                }
            }
        }
    }
    None
}

const RELATIVE_DAYS: &[(&str, i64)] = &[
    ("послезавтра", 2), ("завтра", 1), ("сегодня", 0),
    // Multi-word first: plain "tomorrow" must not eat its own phrase.
    ("day after tomorrow", 2),
    ("tomorrow", 1), ("tmrw", 1), ("tmr", 1),
    ("today", 0), ("tonight", 0),
];

fn try_extract_relative_date(text: &mut String) -> Option<DateToken> {
    let lower = text.to_lowercase();
    for &(word, offset) in RELATIVE_DAYS {
        if let Some(pos) = find_word(&lower, word) {
            text.replace_range(pos..pos + word.len(), "");
            return Some(DateToken::Offset(offset));
        }
    }
    None
}

/// (name, ISO weekday, requires «в»/«во»/«on» prefix). «среда/среду» and «ср»
/// double as ordinary Russian words, so they only count with a preposition.
const WEEKDAYS: &[(&str, i64, bool)] = &[
    ("понедельник", 1, false), ("вторник", 2, false),
    ("среду", 3, true), ("среда", 3, true),
    ("четверг", 4, false), ("пятницу", 5, false), ("пятница", 5, false),
    ("субботу", 6, false), ("суббота", 6, false), ("воскресенье", 7, false),
    ("monday", 1, false), ("tuesday", 2, false), ("wednesday", 3, false),
    ("thursday", 4, false), ("friday", 5, false), ("saturday", 6, false), ("sunday", 7, false),
    ("пн", 1, false), ("вт", 2, false), ("ср", 3, true), ("чт", 4, false),
    ("пт", 5, false), ("сб", 6, false), ("вс", 7, true),
    ("mon", 1, false), ("tue", 2, false), ("wed", 3, false), ("thu", 4, false), ("fri", 5, false),
    // "sat"/"sun" are ordinary English words — they only count after "on".
    ("sat", 6, true), ("sun", 7, true),
];

fn try_extract_weekday(text: &mut String) -> Option<DateToken> {
    let lower = text.to_lowercase();
    for &(name, iso, needs_prefix) in WEEKDAYS {
        let Some(pos) = find_word(&lower, name) else { continue };
        let end = pos + name.len();

        let mut remove_start = pos;
        for prefix in &["во ", "в ", "on "] {
            let head = &lower[..pos];
            if head.ends_with(prefix) {
                let pstart = pos - prefix.len();
                if is_boundary_before(lower.as_bytes(), pstart) {
                    remove_start = pstart;
                    break;
                }
            }
        }
        if needs_prefix && remove_start == pos {
            continue;
        }
        text.replace_range(remove_start..end, "");
        return Some(DateToken::Weekday(iso));
    }
    None
}

/// Apply default duration: if start_time exists but end_time doesn't,
/// set end_time = start_time + 60 minutes.
fn apply_default_duration(result: (Option<i64>, Option<i64>)) -> (Option<i64>, Option<i64>) {
    match result {
        (Some(start), None) => {
            let end = (start + 60).min(1439); // Clamp to 23:59
            (Some(start), Some(end))
        }
        other => other,
    }
}

/// Collapse multiple whitespace characters into single spaces and trim.
fn normalize_whitespace(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    let mut prev_space = true; // Start true to trim leading
    
    for c in s.chars() {
        if c.is_whitespace() {
            if !prev_space {
                result.push(' ');
                prev_space = true;
            }
        } else {
            result.push(c);
            prev_space = false;
        }
    }
    
    // Trim trailing
    if result.ends_with(' ') {
        result.pop();
    }
    
    result
}

// ═══════════════════════════════════════════════════════════════════════════════
// C-ABI EXPORTS
// ═══════════════════════════════════════════════════════════════════════════════

/// Empty result for a null pointer — one shape, reused by both exports.
fn empty_c_parse_result() -> CParseResult {
    CParseResult {
        clean_title: CString::new("").unwrap_or_default().into_raw(),
        start_time: -1,
        end_time: -1,
        priority: 0,
        tags: std::ptr::null_mut(),
        tag_count: 0,
        date_kind: 0,
        date_a: -1,
        date_b: -1,
        date_c: -1,
    }
}

/// Marshal a safe ParsedInput into the C-ABI struct (caller-frees).
fn to_c_parse_result(parsed: ParsedInput) -> CParseResult {
    // Convert tags to C array. Boxed slice (len == capacity BY CONSTRUCTION) so the
    // free side can reconstruct the exact allocation — the previous Vec+forget
    // pattern silently relied on collect() allocating exactly len, which is UB the
    // moment anyone adds a .filter() here.
    let tag_count = parsed.tags.len();
    let tags_ptr = if tag_count > 0 {
        let mut boxed: Box<[*mut c_char]> = parsed.tags
            .into_iter()
            .map(|t| CString::new(t).unwrap_or_default().into_raw())
            .collect::<Vec<_>>()
            .into_boxed_slice();
        let ptr = boxed.as_mut_ptr();
        std::mem::forget(boxed); // Caller frees via ffi_free_parse_result
        ptr
    } else {
        std::ptr::null_mut()
    };

    let (date_kind, date_a, date_b, date_c) = match parsed.date {
        None => (0u8, -1, -1, -1),
        Some(DateToken::Offset(n)) => (1, n, -1, -1),
        Some(DateToken::Weekday(w)) => (2, w, -1, -1),
        Some(DateToken::Explicit(y, m, d)) => (3, y, m, d),
    };

    CParseResult {
        clean_title: CString::new(parsed.clean_title).unwrap_or_default().into_raw(),
        start_time: parsed.start_time.unwrap_or(-1),
        end_time: parsed.end_time.unwrap_or(-1),
        priority: parsed.priority,
        tags: tags_ptr,
        tag_count,
        date_kind,
        date_a,
        date_b,
        date_c,
    }
}

/// Parse a raw input string and return structured tokens.
/// Called on every keystroke from Flutter via dart:ffi.
/// Caller MUST free the result via `ffi_free_parse_result`.
#[no_mangle]
pub extern "C" fn ffi_parse_input(raw_ptr: *const c_char) -> CParseResult {
    if raw_ptr.is_null() {
        return empty_c_parse_result();
    }
    let raw_str = unsafe { CStr::from_ptr(raw_ptr) }.to_str().unwrap_or("");
    to_c_parse_result(parse_input(raw_str))
}

/// Targeted-mode parse: same as `ffi_parse_input` but the pill is already pinned
/// to a day, so a typed calendar date is left as ordinary title text (never
/// re-routes the task). Time/tags/priority still parse. Caller MUST free via
/// `ffi_free_parse_result`.
#[no_mangle]
pub extern "C" fn ffi_parse_input_targeted(raw_ptr: *const c_char) -> CParseResult {
    if raw_ptr.is_null() {
        return empty_c_parse_result();
    }
    let raw_str = unsafe { CStr::from_ptr(raw_ptr) }.to_str().unwrap_or("");
    to_c_parse_result(parse_input_opts(raw_str, false))
}

/// Free a CParseResult returned by `ffi_parse_input`.
/// Must be called by Dart after reading the result.
#[no_mangle]
pub extern "C" fn ffi_free_parse_result(result: CParseResult) {
    unsafe {
        if !result.clean_title.is_null() {
            drop(CString::from_raw(result.clean_title));
        }
        
        if !result.tags.is_null() && result.tag_count > 0 {
            // Mirror of the boxed-slice allocation above: drop each CString, then
            // reclaim the array itself as the Box<[_]> it was created as.
            let tag_slice = std::slice::from_raw_parts_mut(result.tags, result.tag_count);
            for tag_ptr in tag_slice.iter() {
                if !(*tag_ptr).is_null() {
                    drop(CString::from_raw(*tag_ptr));
                }
            }
            drop(Box::from_raw(std::slice::from_raw_parts_mut(result.tags, result.tag_count)));
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_basic_time_parsing() {
        let r = parse_input("Meeting 14:00");
        assert_eq!(r.start_time, Some(840)); // 14*60
        assert_eq!(r.end_time, Some(900));   // 15*60
        assert_eq!(r.clean_title.trim(), "Meeting");
    }
    
    #[test]
    fn test_time_range() {
        let r = parse_input("Call 14:00-15:30");
        assert_eq!(r.start_time, Some(840));
        assert_eq!(r.end_time, Some(930));
        assert_eq!(r.clean_title.trim(), "Call");
    }

    #[test]
    fn test_time_range_crosses_midnight() {
        let r = parse_input("Night shift 23-1");
        assert_eq!(r.start_time, Some(1380));
        assert_eq!(r.end_time, Some(1500)); // 01:00 next day = 1440 + 60
        assert_eq!(r.clean_title.trim(), "Night shift");
    }

    #[test]
    fn test_russian_range_crosses_midnight() {
        let r = parse_input("смена с 23 до 1");
        assert_eq!(r.start_time, Some(1380));
        assert_eq!(r.end_time, Some(1500));
        assert_eq!(r.clean_title.trim(), "смена");
    }
    
    #[test]
    fn test_dot_time() {
        let r = parse_input("Lunch 12.30");
        assert_eq!(r.start_time, Some(750)); // 12*60+30
        assert_eq!(r.end_time, Some(810));
    }
    
    #[test]
    fn test_priority() {
        let r = parse_input("Important task !!");
        assert_eq!(r.priority, 2);
        assert_eq!(r.clean_title.trim(), "Important task");
        
        let r2 = parse_input("Normal task !");
        assert_eq!(r2.priority, 1);
    }
    
    #[test]
    fn test_tags() {
        let r = parse_input("Do thing #work #urgent");
        assert_eq!(r.tags, vec!["work", "urgent"]);
        assert_eq!(r.clean_title.trim(), "Do thing");
    }
    
    #[test]
    fn test_tags_ru_sigil() {
        let r = parse_input("купить хлеб №дом");
        assert_eq!(r.tags, vec!["дом"]);
        assert_eq!(r.clean_title.trim(), "купить хлеб");

        let r2 = parse_input("mix #a №б");
        assert_eq!(r2.tags, vec!["a", "б"]);

        let r3 = parse_input("lone № end");
        assert!(r3.tags.is_empty());
        assert_eq!(r3.clean_title, "lone № end");
    }

    #[test]
    fn test_combined() {
        let r = parse_input("Design review 14:00 #work !!");
        assert_eq!(r.start_time, Some(840));
        assert_eq!(r.priority, 2);
        assert_eq!(r.tags, vec!["work"]);
    }
    
    #[test]
    fn test_russian_at() {
        let r = parse_input("Встреча в 14 часов");
        assert_eq!(r.start_time, Some(840));
        assert_eq!(r.end_time, Some(900));
    }

    #[test]
    fn test_english_pm_suffix() {
        let r = parse_input("call mom 5pm");
        assert_eq!(r.start_time, Some(17 * 60));
        assert_eq!(r.end_time, Some(18 * 60));
        assert_eq!(r.clean_title, "call mom");

        let r2 = parse_input("standup 9 am");
        assert_eq!(r2.start_time, Some(9 * 60));
        assert_eq!(r2.clean_title, "standup");

        let r3 = parse_input("focus 5:30pm");
        assert_eq!(r3.start_time, Some(17 * 60 + 30));
        assert_eq!(r3.clean_title, "focus");
    }

    #[test]
    fn test_english_twelve_edge() {
        assert_eq!(parse_input("flight 12am").start_time, Some(0));
        assert_eq!(parse_input("lunch 12pm").start_time, Some(12 * 60));
    }

    #[test]
    fn test_english_meridiem_word_boundaries() {
        // "am"/"pm" glued into a word is not a time
        let r = parse_input("read 5 among things");
        assert_eq!(r.start_time, None);
        assert_eq!(r.clean_title, "read 5 among things");
        // digit inside a word is not an hour
        let r2 = parse_input("note5pm");
        assert_eq!(r2.start_time, None);
    }

    #[test]
    fn test_english_at() {
        // Bare small hours lean afternoon (1..=7 → PM) — nobody means 05:00
        // by "at 5"; 8..=23 stay literal. Meridiem/24h always wins.
        let r = parse_input("call mom at 5");
        assert_eq!(r.start_time, Some(17 * 60));
        assert_eq!(r.clean_title, "call mom");

        assert_eq!(parse_input("wake at 8").start_time, Some(8 * 60));
        assert_eq!(parse_input("review at 17").start_time, Some(17 * 60));
        assert_eq!(parse_input("call at 5:30").start_time, Some(17 * 60 + 30));
        let r6 = parse_input("gym at 6am");
        assert_eq!(r6.start_time, Some(6 * 60));
        assert_eq!(r6.clean_title, "gym"); // the "at" goes with its time
        // "at" inside a word must not trigger
        let r2 = parse_input("flat 5 keys");
        assert_eq!(r2.start_time, None);
        assert_eq!(r2.clean_title, "flat 5 keys");
    }

    #[test]
    fn test_english_ranges_with_meridiem() {
        // Trailing meridiem distributes: 5-6pm → 17:00–18:00
        let r = parse_input("deep work 5-6pm");
        assert_eq!(r.start_time, Some(17 * 60));
        assert_eq!(r.end_time, Some(18 * 60));
        assert_eq!(r.clean_title, "deep work");
        // Crossing noon: 11-1pm → 11:00–13:00
        let r2 = parse_input("brunch 11-1pm");
        assert_eq!(r2.start_time, Some(11 * 60));
        assert_eq!(r2.end_time, Some(13 * 60));
        // Both sides explicit: 8am-5pm
        let r3 = parse_input("shift 8am-5pm");
        assert_eq!(r3.start_time, Some(8 * 60));
        assert_eq!(r3.end_time, Some(17 * 60));
        // Leading meridiem, bare end: 5pm-7 → 17:00–19:00
        let r4 = parse_input("jam 5pm-7");
        assert_eq!(r4.start_time, Some(17 * 60));
        assert_eq!(r4.end_time, Some(19 * 60));
    }

    #[test]
    fn test_english_from_to() {
        // The English «с X до Y». Bare hours stay literal, like the Russian.
        let r = parse_input("focus from 12 to 16");
        assert_eq!(r.start_time, Some(12 * 60));
        assert_eq!(r.end_time, Some(16 * 60));
        assert_eq!(r.clean_title, "focus");
        // A meridiem colors the range by the dash-range rules.
        let r2 = parse_input("shift from 9 to 5pm");
        assert_eq!(r2.start_time, Some(9 * 60));
        assert_eq!(r2.end_time, Some(17 * 60));
        // Crossing midnight, start-side meridiem only.
        let r3 = parse_input("party from 11pm to 2");
        assert_eq!(r3.start_time, Some(23 * 60));
        assert_eq!(r3.end_time, Some(26 * 60));
        // Full HH:MM on both sides.
        let r4 = parse_input("from 5:30 to 6:15 rehearsal");
        assert_eq!(r4.start_time, Some(330));
        assert_eq!(r4.end_time, Some(375));
        assert_eq!(r4.clean_title, "rehearsal");
    }

    #[test]
    fn test_english_slang_days() {
        assert_eq!(parse_input("call mom tmr").date, Some(DateToken::Offset(1)));
        let r0 = parse_input("gym tmrw 9am");
        assert_eq!(r0.date, Some(DateToken::Offset(1)));
        assert_eq!(r0.start_time, Some(9 * 60));
        assert_eq!(parse_input("finish it tonight").date, Some(DateToken::Offset(0)));
        let r = parse_input("dentist day after tomorrow");
        assert_eq!(r.date, Some(DateToken::Offset(2)));
        assert_eq!(r.clean_title, "dentist");
    }

    #[test]
    fn test_preposition_before_date() {
        // "на 12 июля" must read as July 12, not 12:00 + orphan "июля".
        let r = parse_input("покушать на 12 июля");
        assert_eq!(r.date, Some(DateToken::Explicit(0, 7, 12)));
        assert_eq!(r.start_time, None);
        assert_eq!(r.clean_title, "покушать");

        let r2 = parse_input("отчёт на 15.07");
        assert_eq!(r2.date, Some(DateToken::Explicit(0, 7, 15)));
        assert_eq!(r2.clean_title, "отчёт");

        let r3 = parse_input("праздник в 12 июля");
        assert_eq!(r3.date, Some(DateToken::Explicit(0, 7, 12)));
        assert_eq!(r3.clean_title, "праздник");

        let r4 = parse_input("call on jul 12");
        assert_eq!(r4.date, Some(DateToken::Explicit(0, 7, 12)));
        assert_eq!(r4.clean_title, "call");

        // Regression: bare "на 12" with NO month stays a 12:00 time.
        let r5 = parse_input("встреча на 12");
        assert_eq!(r5.start_time, Some(12 * 60));
        assert_eq!(r5.date, None);
    }

    #[test]
    fn test_russian_noon_midnight() {
        let r = parse_input("обед в полдень");
        assert_eq!(r.start_time, Some(12 * 60));
        assert_eq!(r.clean_title, "обед");
        assert_eq!(parse_input("релиз в полночь").start_time, Some(0));
        assert_eq!(parse_input("сон полночь").start_time, Some(0));
    }

    #[test]
    fn test_noon_midnight() {
        let r = parse_input("lunch at noon");
        assert_eq!(r.start_time, Some(12 * 60));
        assert_eq!(r.clean_title, "lunch");
        let r2 = parse_input("release midnight");
        assert_eq!(r2.start_time, Some(0));
        assert_eq!(r2.clean_title, "release");
    }

    #[test]
    fn test_weekday_en_sat_sun_need_prefix() {
        // "sat"/"sun" are ordinary English words — only "on sat"/"on sun" count.
        assert_eq!(parse_input("hike on sat").date, Some(DateToken::Weekday(6)));
        assert_eq!(parse_input("call dad on sun").date, Some(DateToken::Weekday(7)));
        assert_eq!(parse_input("sat with mom").date, None);
        assert_eq!(parse_input("sun was out").date, None);
        assert_eq!(parse_input("saturday market").date, Some(DateToken::Weekday(6)));
        assert_eq!(parse_input("sunday reset").date, Some(DateToken::Weekday(7)));
    }
    
    #[test]
    fn test_russian_pm() {
        let r = parse_input("Ужин 9 вечера");
        assert_eq!(r.start_time, Some(21 * 60));
    }
    
    #[test]
    fn test_russian_am() {
        let r = parse_input("Зарядка 7 утра");
        assert_eq!(r.start_time, Some(7 * 60));
    }
    
    #[test]
    fn test_date_tomorrow_ru() {
        let r = parse_input("сдать отчёт завтра в 9");
        assert_eq!(r.date, Some(DateToken::Offset(1)));
        assert_eq!(r.start_time, Some(540));
        assert_eq!(r.clean_title, "сдать отчёт");
    }

    #[test]
    fn test_date_aftertomorrow_and_today() {
        assert_eq!(parse_input("post послезавтра").date, Some(DateToken::Offset(2)));
        assert_eq!(parse_input("call today").date, Some(DateToken::Offset(0)));
        assert_eq!(parse_input("call tomorrow").date, Some(DateToken::Offset(1)));
    }

    #[test]
    fn test_date_weekday_ru_full_and_short() {
        let r = parse_input("созвон в пятницу 15:00");
        assert_eq!(r.date, Some(DateToken::Weekday(5)));
        assert_eq!(r.start_time, Some(900));
        assert_eq!(r.clean_title, "созвон");
        assert_eq!(parse_input("зал пн").date, Some(DateToken::Weekday(1)));
        assert_eq!(parse_input("во вторник врач").date, Some(DateToken::Weekday(2)));
        assert_eq!(parse_input("в среду").date, Some(DateToken::Weekday(3)));
        // «среда» без предлога — обычное слово (рабочая среда), не дата
        assert_eq!(parse_input("обновить среду").date, None);
    }

    #[test]
    fn test_date_weekday_en() {
        assert_eq!(parse_input("gym friday").date, Some(DateToken::Weekday(5)));
        assert_eq!(parse_input("gym fri").date, Some(DateToken::Weekday(5)));
        assert_eq!(parse_input("we sat down").date, None);
        assert_eq!(parse_input("brunch saturday").date, Some(DateToken::Weekday(6)));
    }

    #[test]
    fn test_date_numeric_dotted() {
        assert_eq!(parse_input("рейс 15.07").date, Some(DateToken::Explicit(0, 7, 15)));
        assert_eq!(parse_input("рейс 15.07.2026").date, Some(DateToken::Explicit(2026, 7, 15)));
        let r = parse_input("Lunch 12.30");
        assert_eq!(r.date, None);
        assert_eq!(r.start_time, Some(750));
        assert_eq!(parse_input("отпуск 25.07").date, Some(DateToken::Explicit(0, 7, 25)));
    }

    #[test]
    fn test_date_month_name() {
        assert_eq!(parse_input("день рождения 15 июля").date, Some(DateToken::Explicit(0, 7, 15)));
        assert_eq!(parse_input("release jul 15").date, Some(DateToken::Explicit(0, 7, 15)));
        assert_eq!(parse_input("release 15 jul").date, Some(DateToken::Explicit(0, 7, 15)));
    }

    #[test]
    fn test_date_in_days() {
        assert_eq!(parse_input("сдать через 3 дня").date, Some(DateToken::Offset(3)));
        assert_eq!(parse_input("через неделю отпуск").date, Some(DateToken::Offset(7)));
        assert_eq!(parse_input("через 2 недели релиз").date, Some(DateToken::Offset(14)));
        assert_eq!(parse_input("через два дня зал").date, Some(DateToken::Offset(2)));
        assert_eq!(parse_input("pay rent in 5 days").date, Some(DateToken::Offset(5)));
        assert_eq!(parse_input("release in a week").date, Some(DateToken::Offset(7)));
        assert_eq!(parse_input("believe in magic").date, None);
        assert_eq!(parse_input("check in 10 minutes").date, None);
        let r = parse_input("через 3 дня сдать отчёт");
        assert_eq!(r.clean_title, "сдать отчёт");
    }

    #[test]
    fn test_date_word_boundaries() {
        assert_eq!(parse_input("завтрак с командой").date, None);
        assert_eq!(parse_input("отправить письмо").date, None);
    }

    #[test]
    fn test_date_combined_full() {
        let r = parse_input("в пятницу 15:00 демо !! #работа");
        assert_eq!(r.date, Some(DateToken::Weekday(5)));
        assert_eq!(r.start_time, Some(900));
        assert_eq!(r.priority, 2);
        assert_eq!(r.tags, vec!["работа"]);
        assert_eq!(r.clean_title, "демо");
    }

    #[test]
    fn test_plain_text() {
        let r = parse_input("Buy groceries");
        assert_eq!(r.start_time, None);
        assert_eq!(r.end_time, None);
        assert_eq!(r.priority, 0);
        assert!(r.tags.is_empty());
        assert_eq!(r.clean_title, "Buy groceries");
    }

    // ── Targeted mode (pill pinned to a day): the date must NOT be extracted;
    //    it stays as ordinary title text (zero lost input). Time still parses. ──

    #[test]
    fn test_targeted_keeps_date_as_text() {
        // Normal parse would strip "14 июля" and route elsewhere.
        let normal = parse_input("позвонить маме 14 июля");
        assert_eq!(normal.date, Some(DateToken::Explicit(0, 7, 14)));
        assert_eq!(normal.clean_title, "позвонить маме");

        // Targeted parse: date stays in the title, no date token.
        let targeted = parse_input_opts("позвонить маме 14 июля", false);
        assert_eq!(targeted.date, None);
        assert_eq!(targeted.clean_title, "позвонить маме 14 июля");
    }

    #[test]
    fn test_targeted_keeps_relative_date_but_parses_time() {
        // "tomorrow" stays as text (pinned day wins), but 15:00 still schedules.
        let targeted = parse_input_opts("call mom tomorrow 15:00", false);
        assert_eq!(targeted.date, None);
        assert_eq!(targeted.start_time, Some(900));
        assert_eq!(targeted.clean_title, "call mom tomorrow");
    }

    #[test]
    fn test_targeted_still_parses_tags_and_priority() {
        let targeted = parse_input_opts("отчёт 15.07 !! #работа", false);
        assert_eq!(targeted.date, None);
        assert_eq!(targeted.priority, 2);
        assert_eq!(targeted.tags, vec!["работа"]);
        // The date words remain; tokens for priority/tags are still stripped.
        assert_eq!(targeted.clean_title, "отчёт 15.07");
    }
}
