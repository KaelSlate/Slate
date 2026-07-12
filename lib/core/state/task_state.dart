import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../engine/capture_destination.dart';
import '../engine/slate_core_bridge.dart';

final taskStateProvider = ChangeNotifierProvider<TaskState>((ref) => TaskState());

/// Phase 3 — Zero-Latency Offline Task State
///
/// Dart is a dumb renderer. All task data lives in Rust:
///   - In-memory TaskStore (nanosecond reads)
///   - Local SQLite vault (instant persistence)
///   - Background sync worker (Supabase push/pull with LWW)
///
/// This class merely:
///   1. Calls initEngine() on boot (Rust loads from SQLite in <50ms)
///   2. Keeps a local List<RustTask> mirror for notifyListeners()
///   3. Forwards all mutations to Rust (which handles SQLite + sync)

class TaskState extends ChangeNotifier {
  final SlateCore core = SlateCore();

  List<RustTask> _tasks = [];
  bool _loaded = false;

  // Granular Notifiers for targeted UI Reactivity
  final Map<int, ValueNotifier<List<RustTask>>> _tasksByDateNotifiers = {};
  final Map<String, ValueNotifier<List<RustTask>>> _tasksByHourNotifiers = {};

  /// P4: lightweight mutation counter. Widgets that need "any task changed
  /// anywhere" (e.g. the week header's done/total counter) listen to THIS
  /// instead of the whole ChangeNotifier — so a single toggle no longer
  /// rebuilds the entire active view. Per-date data still flows through
  /// [tasksForDateNotifier]/[tasksForHourNotifier].
  final ValueNotifier<int> mutationTick = ValueNotifier(0);

  void _bumpTick() => mutationTick.value++;

  List<RustTask> get tasks => _tasks;
  bool get loaded => _loaded;

  /// Order for the «TO SCHEDULE» pool: importance first, freshest capture on top.
  /// `createdAt` is the task's DAY and `updatedAt` moves on every toggle, so the
  /// only honest recency signal is the store's insert order — reversed here.
  /// Neither key changes when a task is checked off, so nothing ever jumps.
  static List<RustTask> orderUnallocated(List<RustTask> src) {
    final rank = <String, int>{};
    for (var i = 0; i < src.length; i++) {
      rank[src[i].id] = i;
    }
    final out = List<RustTask>.of(src);
    out.sort((a, b) {
      final p = b.priority.compareTo(a.priority);
      return p != 0 ? p : rank[b.id]!.compareTo(rank[a.id]!);
    });
    return out;
  }

  /// Order for the Inbox: importance first, freshest capture on top.
  /// It cannot reuse [orderUnallocated]'s insert-order rank — the Inbox reads
  /// the global mirror, which is rehydrated from `all_tasks()` (a HashMap walk,
  /// so the order is arbitrary after every restart). An inbox task only ever
  /// gets `isInbox` at creation, so its `createdAt` is a real capture timestamp
  /// (day tasks get a day-start instead) and is the honest recency key here.
  /// Neither key moves when an item is checked off — nothing jumps.
  static List<RustTask> orderInbox(List<RustTask> src) {
    final out = List<RustTask>.of(src);
    out.sort((a, b) {
      final p = b.priority.compareTo(a.priority);
      if (p != 0) return p;
      final t = b.createdAt.compareTo(a.createdAt);
      return t != 0 ? t : a.id.compareTo(b.id);
    });
    return out;
  }

  /// Retrieve a localized ValueNotifier for a specific date's tasks
  ValueNotifier<List<RustTask>> tasksForDateNotifier(int dateTs) {
    if (!_tasksByDateNotifiers.containsKey(dateTs)) {
      _tasksByDateNotifiers[dateTs] = ValueNotifier(core.tasksForDate(dateTs));
    }
    return _tasksByDateNotifiers[dateTs]!;
  }
  
  /// Retrieve a localized ValueNotifier for a specific hour's tasks
  ValueNotifier<List<RustTask>> tasksForHourNotifier(int dateTs, int hour) {
    final key = '${dateTs}_$hour';
    if (!_tasksByHourNotifiers.containsKey(key)) {
      _tasksByHourNotifiers[key] = ValueNotifier(core.tasksForHour(dateTs, hour));
    }
    return _tasksByHourNotifiers[key]!;
  }

  // Supabase config — injected at compile time via --dart-define flags.
  // NEVER hardcode API keys in source code.
  static const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const _supabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  TaskState() {
    _initEngine();
  }

  /// Initialize the Rust offline engine.
  /// Rust loads tasks from local SQLite (<50ms), then spawns sync worker.
  Future<void> _initEngine() async {
    // Determine the local DB path
    final dbPath = await _resolveDbPath();

    // Securely retrieve or generate the 256-bit DB encryption key
    final dbKey = await _resolveDbKey();

    // Initialize Rust engine: SQLite + memory store + sync worker
    final count = core.initEngine(
      dbPath: dbPath,
      supabaseUrl: _supabaseUrl,
      supabaseKey: _supabaseKey,
      dbKey: dbKey,
    );

    if (count >= 0) {
      // Hydrate Dart's local mirror from Rust store
      _tasks = core.getAllTasks();
      _loaded = true;
      debugPrint('✓ TaskState: Engine ready with $count tasks from local DB');
    } else {
      // Engine init failed — fall back to stub tasks
      debugPrint('⚠ TaskState: Engine init failed, using stub data');
      _tasks = List.generate(5, (i) =>
        core.createTask('Sample task ${i + 1}', DateTime.now().millisecondsSinceEpoch));
      _loaded = true;
    }

    notifyListeners();
  }

  /// Resolve the SQLite database file path.
  Future<String> _resolveDbPath() async {
    // Use the OS-compliant documents directory for mobile/desktop
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/slate_data/tasks.db';
  }

  /// Retrieve or cryptographically generate the SQLite payload encryption key.
  Future<String> _resolveDbKey() async {
    const storage = FlutterSecureStorage();
    String? key = await storage.read(key: 'slate_db_key');
    if (key == null) {
      final rng = Random.secure();
      final bytes = List<int>.generate(32, (i) => rng.nextInt(256));
      key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await storage.write(key: 'slate_db_key', value: key);
    }
    return key;
  }

  /// Create a new task. Rust persists to SQLite + queues sync instantly.
  Future<void> createTask(String title, int targetTs) async {
    if (title.trim().isEmpty) return;
    final newTask = core.createTask(title.trim(), targetTs);
    _tasks.insert(0, newTask);
    _invalidateTaskCaches(newTask);
    _bumpTick();
    notifyListeners();
    // No Supabase call — Rust sync worker handles it
  }

  /// Create a new Inbox task (is_inbox = true).
  /// Dart calls ffi_create_inbox_task → Rust sets is_inbox=true → SQLite + Sync.
  /// ffi_create_inbox_task carries no NLP metadata, so priority/tags (from the
  /// parser) are persisted with a follow-up ffi_update_task_ex — otherwise a
  /// captured «#дом идея !!» landed in the inbox stripped of its tag/importance.
  Future<void> createInboxTask(String title,
      {int priority = 0, List<String> tags = const []}) async {
    if (title.trim().isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var newTask = core.createInboxTask(title.trim(), now);
    if (priority != 0 || tags.isNotEmpty) {
      newTask = newTask.copyWith(priority: priority, tags: tags);
      core.updateTaskInStore(newTask);
    }
    _tasks.insert(0, newTask);
    _invalidateTaskCaches(newTask);
    _bumpTick();
    notifyListeners();
  }

  /// Phase 5: Create a task with full NLP-parsed metadata via ffi_create_task_ex.
  /// [cleanTitle] is the NLP-stripped title; [result] carries time/priority/tags.
  Future<void> createSmartTask({
    required String cleanTitle,
    required int dayTs,
    required ParseResult result,
  }) async {
    if (cleanTitle.trim().isEmpty) return;
    final newTask = core.createTaskEx(
      title: cleanTitle.trim(),
      dayTs: dayTs,
      startTime: result.startTime,
      endTime: result.endTime,
      priority: result.priority,
      tags: result.tags,
    );
    _tasks.insert(0, newTask);
    _invalidateTaskCaches(newTask);
    _bumpTick();
    notifyListeners();
  }

  /// Create a task at a resolved capture destination (Inbox or a concrete day).
  /// Single entry point for both the in-app pill and the global quick capture.
  Future<void> createCaptured(
      String cleanTitle, ParseResult result, CaptureDestination dest) async {
    if (cleanTitle.trim().isEmpty) return;
    if (dest.toInbox) {
      return createInboxTask(cleanTitle,
          priority: result.priority, tags: result.tags);
    }
    final newTask = core.createTaskEx(
      title: cleanTitle.trim(),
      dayTs: dest.day!.millisecondsSinceEpoch,
      startTime: dest.startTime,
      endTime: dest.endTime,
      priority: result.priority,
      tags: result.tags,
    );
    _tasks.insert(0, newTask);
    _invalidateTaskCaches(newTask);
    _bumpTick();
    notifyListeners();
  }

  /// Update an existing task.
  void updateTask(RustTask task) {
    // Capture the PREVIOUS version before overwriting: if the edit moved the
    // task to another day (or hour), the old day's notifier must also refresh —
    // otherwise the task keeps showing on the old day until restart.
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    final previous = idx != -1 ? _tasks[idx] : null;
    core.updateTaskInStore(task);
    if (idx != -1) _tasks[idx] = task;
    if (previous != null &&
        (previous.createdAt != task.createdAt ||
            previous.startTime != task.startTime)) {
      _invalidateTaskCaches(previous);
    }
    _invalidateTaskCaches(task);
    _bumpTick();
    notifyListeners();
  }

  // ── Drag & Drop reschedule intents ──
  // Raw-constructor rebuild: copyWith can't null out startTime/endTime, and a
  // drop must clear isInbox or the task stays invisible on the calendar.

  /// Drop on a week/month day cell: assign the day, keep time-of-day.
  void assignToDay(RustTask task, DateTime day) =>
      updateTask(_rescheduled(task, _midnightMs(day), task.startTime, task.endTime));

  /// Drop on the timeline ribbon: assign day + intra-day time.
  void scheduleAt(RustTask task, DateTime day, int startMinutes, int? endMinutes) =>
      updateTask(_rescheduled(task, _midnightMs(day), startMinutes, endMinutes));

  /// Drop on the planning pane: keep the day, clear the time slot.
  void unschedule(RustTask task, DateTime day) =>
      updateTask(_rescheduled(task, _midnightMs(day), null, null));

  static int _midnightMs(DateTime day) =>
      DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;

  static RustTask _rescheduled(RustTask t, int dayMs, int? startTime, int? endTime) {
    return RustTask(
      id: t.id,
      title: t.title,
      isCompleted: t.isCompleted,
      createdAt: dayMs,
      updatedAt: t.updatedAt,
      startAt: t.startAt,
      endAt: t.endAt,
      userId: t.userId,
      isInbox: false,
      startTime: startTime,
      endTime: endTime,
      priority: t.priority,
      tags: t.tags,
    );
  }

  /// Toggle task completion. Rust persists + queues sync.
  void toggleTask(RustTask task) {
    final toggled = core.toggleTask(task);
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) _tasks[idx] = toggled;
    _invalidateTaskCaches(toggled);
    _bumpTick();
    notifyListeners();
    // No Supabase call — Rust sync worker handles it
  }

  /// Delete a task. Rust soft-deletes in SQLite + queues sync.
  void deleteTask(RustTask task) {
    _tasks.removeWhere((t) => t.id == task.id);
    core.removeTaskFromStore(task.id);
    _invalidateTaskCaches(task);
    _bumpTick();
    notifyListeners();
    // No Supabase call — Rust sync worker handles it
  }

  /// Refresh the Dart mirror from Rust store.
  /// Useful after sync worker has merged remote changes.
  void refreshFromStore() {
    _tasks = core.getAllTasks();
    _refreshAllCaches();
    _bumpTick();
    notifyListeners();
  }

  // ── Cache Invalidation Helpers ──

  void _invalidateTaskCaches(RustTask task) {
    // If it belongs to a date/time, trigger those notifiers to reload specifically.
    final date = DateTime.fromMillisecondsSinceEpoch(task.createdAt);
    final dateTs = DateTime(date.year, date.month, date.day).millisecondsSinceEpoch;
    if (_tasksByDateNotifiers.containsKey(dateTs)) {
      _tasksByDateNotifiers[dateTs]!.value = core.tasksForDate(dateTs);
    }
    
    // Invalidate the hour the task was actually assigned to, if any.
    // If it has no start time, we might still want to invalidate the hour it was created just in case,
    // but the timeline only renders allocated tasks anyway.
    final targetHour = task.startTime != null ? task.startTime! ~/ 60 : date.hour;
    final hourKey = '${dateTs}_$targetHour';
    if (_tasksByHourNotifiers.containsKey(hourKey)) {
      _tasksByHourNotifiers[hourKey]!.value = core.tasksForHour(dateTs, targetHour);
    }
  }
  
  void _refreshAllCaches() {
    for (final entry in _tasksByDateNotifiers.entries) {
      entry.value.value = core.tasksForDate(entry.key);
    }
    for (final entry in _tasksByHourNotifiers.entries) {
      final parts = entry.key.split('_');
      entry.value.value = core.tasksForHour(int.parse(parts[0]), int.parse(parts[1]));
    }
  }
}
