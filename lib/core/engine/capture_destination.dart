import 'slate_core_bridge.dart';

/// Where a captured task lands. Pure resolution of the parse result:
///   no date + no time  → Inbox
///   no date + time     → today; if the time already passed → tomorrow
///   date + time        → that day at that time
///   date + no time     → that day, unallocated
/// With [viewedDay] (in-app pill): no Inbox, no roll-forward — an explicit
/// date in the text overrides the viewed day, otherwise the viewed day wins.
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
        var d = DateTime(r.dateA > 0 ? r.dateA : now.year, r.dateB, r.dateC);
        if (r.dateA <= 0 && d.isBefore(today)) {
          d = DateTime(now.year + 1, r.dateB, r.dateC);
        }
        day = d;
      }
      break;
  }
  if (day == null && viewedDay != null) {
    day = DateTime(viewedDay.year, viewedDay.month, viewedDay.day);
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

/// Human label for a landing day ("Today" / "Tomorrow" / "Mon · Jul 14").
String dayLabel(DateTime day, DateTime today) {
  if (day == today) return 'Today';
  if (day == today.add(const Duration(days: 1))) return 'Tomorrow';
  return '${_weekdays[day.weekday - 1]} · ${_months[day.month - 1]} ${day.day}';
}
