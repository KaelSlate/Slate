import 'slate_core_bridge.dart';

/// Where a captured task lands. Pure resolution of the parse result:
///   no date + no time  → Inbox
///   no date + time     → today; if the time already passed → tomorrow
///   date + time        → that day at that time
///   date + no time     → that day, unallocated
///   explicit PAST date → that exact past day (never a silent +1-year roll —
///                        the chip shows its age so the user sees it before Enter)
/// With [viewedDay] (targeted pill: day-view `C`/«+», mouse-«+»): the pinned day
/// ALWAYS wins — a typed date never re-routes the task (in practice the targeted
/// parse already yields dateKind 0). Time still schedules within that day.
class CaptureDestination {
  final bool toInbox;
  final DateTime? day; // local midnight
  final int? startTime;
  final int? endTime;
  final String label;

  const CaptureDestination({
    required this.toInbox,
    this.day,
    this.startTime,
    this.endTime,
    required this.label,
  });
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

CaptureDestination resolveCapture(ParseResult r, DateTime now, {DateTime? viewedDay}) {
  final today = DateTime(now.year, now.month, now.day);

  // ── TARGETED: the pill is pinned to a day → that day always wins ──────────
  // A typed date never re-routes it (the targeted parse yields dateKind 0; this
  // also guards any caller passing a non-targeted parse). Time still applies.
  if (viewedDay != null) {
    final day = DateTime(viewedDay.year, viewedDay.month, viewedDay.day);
    return CaptureDestination(
      toInbox: false,
      day: day,
      startTime: r.startTime,
      endTime: r.endTime,
      label: _label(day, today, r),
    );
  }

  // ── NON-TARGETED: honor the typed date; no silent year-forward roll ───────
  DateTime? day;
  switch (r.dateKind) {
    case 1:
      day = today.add(Duration(days: r.dateA));
      break;
    case 2:
      day = today.add(Duration(days: (r.dateA - now.weekday) % 7));
      break;
    case 3:
      if (r.dateB >= 1 && r.dateB <= 12 && r.dateC >= 1 && r.dateC <= 31) {
        // Explicit year if given (dateA > 0); otherwise this year — EVEN IF it
        // already passed. We never silently jump a bare past date to next year:
        // the chip surfaces its age ("· 2d ago") so the user sees exactly how
        // the words were understood before Enter (honesty + nothing lost).
        day = DateTime(r.dateA > 0 ? r.dateA : now.year, r.dateB, r.dateC);
      }
      break;
  }
  if (day == null) {
    if (!r.hasTime) return const CaptureDestination(toInbox: true, label: 'Inbox');
    day = today;
    if (r.startTime! < now.hour * 60 + now.minute) {
      day = today.add(const Duration(days: 1));
    }
  }
  return CaptureDestination(
    toInbox: false,
    day: day,
    startTime: r.startTime,
    endTime: r.endTime,
    label: _label(day, today, r),
  );
}

String _label(DateTime day, DateTime today, ParseResult r) {
  final d = dayLabel(day, today);
  return r.hasTime ? '$d ${r.startTimeFormatted}' : d;
}

/// Human label for a landing day ("Today" / "Tomorrow" / "Yesterday" /
/// "Mon · Jul 14"). A past day (older than yesterday) appends a calm age
/// ("Jul 14 · 2d ago") so a mistaken past date is obvious before Enter.
String dayLabel(DateTime day, DateTime today) {
  if (day == today) return 'Today';
  if (day == today.add(const Duration(days: 1))) return 'Tomorrow';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  if (day.isBefore(today)) {
    return '${_months[day.month - 1]} ${day.day} · ${_ageLabel(day, today)}';
  }
  return '${_weekdays[day.weekday - 1]} · ${_months[day.month - 1]} ${day.day}';
}

/// Compact calm age for a past landing day: "2d ago" / "3w ago" / "5mo ago" /
/// "2y ago". Never a guilt word — just an honest marker so nothing feels lost.
String _ageLabel(DateTime day, DateTime today) {
  final days = today.difference(day).inDays;
  if (days < 7) return '${days}d ago';
  if (days < 30) return '${(days / 7).floor()}w ago';
  if (days < 365) return '${(days / 30).floor()}mo ago';
  return '${(days / 365).floor()}y ago';
}
