/// SLATE Core Engine - Real FFI Bridge
/// Phase 3: Zero-Latency Offline Engine
///
/// Dart is a dumb renderer. Rust owns all state:
///   - In-memory TaskStore (nanosecond reads)
///   - Local SQLite vault (crash-safe persistence)
///   - Background sync worker (Supabase push/pull with LWW)
///
/// Dart calls initEngine() on boot, then create/toggle/delete.
/// Rust handles persistence + sync.

import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'package:ffi/ffi.dart'; // Core string and memory functions


// ════════════════════════════════════════════════════════════════════════════
// FFI TYPE DEFINITIONS
// ════════════════════════════════════════════════════════════════════════════

// C function signatures for Rust exports
typedef HealthCheckNative = Pointer<Utf8> Function();
typedef HealthCheckDart = Pointer<Utf8> Function();

typedef CalculateMagneticSnapNative = Double Function(Double, Double, Double);
typedef CalculateMagneticSnapDart = double Function(double, double, double);

typedef CalculateDayTransitionOpacityNative = Double Function(Double, Double);
typedef CalculateDayTransitionOpacityDart = double Function(double, double);

final class CTask extends Struct {
  external Pointer<Utf8> id;
  external Pointer<Utf8> title;
  @Bool() external bool isCompleted;
  @Bool() external bool isInbox;
  @Int64() external int created_at;
  @Int64() external int updated_at;
  @Int64() external int start_at;
  @Int64() external int end_at;
  /// Intra-day start time (minutes since midnight), -1 if unset.
  @Int64() external int start_time;
  /// Intra-day end time (minutes since midnight), -1 if unset.
  @Int64() external int end_time;
  /// Priority (0=Normal, 1=Important, 2=Very Important).
  @Uint8() external int priority;
  /// Zero-copy tag array: pointer to an array of NUL-terminated strings.
  /// Freed by Rust via ffi_free_task / ffi_free_task_list.
  external Pointer<Pointer<Utf8>> tags;
  @Size() external int tag_count;
}

final class CTaskList extends Struct {
  external Pointer<CTask> data;
  @Size() external int len;
  @Size() external int capacity;
}

// Phase 3: Engine init / graceful shutdown
typedef FfiInitEngineNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef FfiInitEngineDart = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef FfiShutdownEngineNative = Int32 Function();
typedef FfiShutdownEngineDart = int Function();

// Phase 3: Get all tasks
typedef FfiGetAllTasksNative = CTaskList Function();
typedef FfiGetAllTasksDart = CTaskList Function();

typedef FfiRemoveTaskNative = Int32 Function(Pointer<Utf8>);
typedef FfiRemoveTaskDart = int Function(Pointer<Utf8>);

typedef FfiCreateTaskNative = Pointer<CTask> Function(Pointer<Utf8>, Int64);
typedef FfiCreateTaskDart = Pointer<CTask> Function(Pointer<Utf8>, int);

typedef FfiCreateInboxTaskNative = Pointer<CTask> Function(Pointer<Utf8>, Int64);
typedef FfiCreateInboxTaskDart = Pointer<CTask> Function(Pointer<Utf8>, int);

typedef FfiToggleTaskNative = Pointer<CTask> Function(Pointer<Utf8>);
typedef FfiToggleTaskDart = Pointer<CTask> Function(Pointer<Utf8>);

typedef FfiTaskCountNative = Uint32 Function();
typedef FfiTaskCountDart = int Function();

typedef FfiTasksForDateNative = CTaskList Function(Int64);
typedef FfiTasksForDateDart = CTaskList Function(int);

typedef FfiFreeStringNative = Void Function(Pointer<Utf8>);
typedef FfiFreeStringDart = void Function(Pointer<Utf8>);

typedef FfiFreeTaskNative = Void Function(Pointer<CTask>);
typedef FfiFreeTaskDart = void Function(Pointer<CTask>);

typedef FfiFreeTaskListNative = Void Function(CTaskList);
typedef FfiFreeTaskListDart = void Function(CTaskList);

final class CDayCell extends Struct {
  @Int64() external int dateTimestamp;
  @Uint8() external int dayOfWeek;
  @Uint8() external int dayOfMonth;
  @Bool() external bool isToday;
  @Uint32() external int taskCount;
  @Uint32() external int completedCount;
  // ABI padding — must exist to mirror the #[repr(C)] Rust struct layout.
  // ignore: unused_field
  @Uint16() external int _pad;
}

final class CDayCellList extends Struct {
  external Pointer<CDayCell> data;
  @Size() external int len;
  @Size() external int capacity;
}

final class COptDayCell extends Struct {
  external CDayCell cell;
  @Uint8() external int isValid;
  @Uint8() external int pad0;
  @Uint16() external int pad1;
  @Uint32() external int pad2;
}

final class CMonthCellList extends Struct {
  external Pointer<COptDayCell> data;
  @Size() external int len;
  @Size() external int capacity;
}

final class CHourSlot extends Struct {
  @Uint8() external int hour;
  @Bool() external bool isCurrent;
  @Uint16() external int pad0;
  @Uint32() external int pad1;
  @Double() external double xOffset;
  @Uint32() external int taskCount;
  @Uint32() external int pad2;
}

final class CHourSlotList extends Struct {
  external Pointer<CHourSlot> data;
  @Size() external int len;
  @Size() external int capacity;
}

final class CSpatialFrame extends Struct {
  @Int64() external int visibleStart;
  @Int64() external int visibleEnd;
  @Double() external double hourWidth;
  @Double() external double currentOffset;
  @Double() external double totalWidth;
}

final class CU32List extends Struct {
  external Pointer<Uint32> data;
  @Size() external int len;
  @Size() external int capacity;
}

// Phase 3: Spatial & Physics FFI
typedef FfiCalculateFlowFrameNative = CSpatialFrame Function(Int64, Double, Double);
typedef FfiCalculateFlowFrameDart = CSpatialFrame Function(int, double, double);

typedef FfiGenerateHourSlotsNative = CHourSlotList Function(Int64, Double, Double, Pointer<Uint32>, IntPtr);
typedef FfiGenerateHourSlotsDart = CHourSlotList Function(int, double, double, Pointer<Uint32>, int);

typedef FfiGenerateWeekCellsNative = CDayCellList Function(Int64);
typedef FfiGenerateWeekCellsDart = CDayCellList Function(int);

typedef FfiGenerateMonthCellsNative = CMonthCellList Function(Int32, Uint32);
typedef FfiGenerateMonthCellsDart = CMonthCellList Function(int, int);

typedef FfiTaskCountsByHourNative = CU32List Function(Int64);
typedef FfiTaskCountsByHourDart = CU32List Function(int);

typedef FfiTasksForHourNative = CTaskList Function(Int64, Uint8);
typedef FfiTasksForHourDart = CTaskList Function(int, int);

typedef FfiCalculateYearHeatmapNative = CU32List Function(Int32);
typedef FfiCalculateYearHeatmapDart = CU32List Function(int);

// Memory free definitions for new lists
typedef FfiFreeDayCellListNative = Void Function(CDayCellList);
typedef FfiFreeDayCellListDart = void Function(CDayCellList);

typedef FfiFreeMonthCellListNative = Void Function(CMonthCellList);
typedef FfiFreeMonthCellListDart = void Function(CMonthCellList);

typedef FfiFreeHourSlotListNative = Void Function(CHourSlotList);
typedef FfiFreeHourSlotListDart = void Function(CHourSlotList);

typedef FfiFreeU32ListNative = Void Function(CU32List);
typedef FfiFreeU32ListDart = void Function(CU32List);

typedef FfiCalculateSpringSnapNative = Double Function(Double, Double, Double, Double, Pointer<Double>);
typedef FfiCalculateSpringSnapDart = double Function(double, double, double, double, Pointer<Double>);

typedef FfiCalculateClockHandsNative = Double Function(Int64, Pointer<Double>, Pointer<Double>);
typedef FfiCalculateClockHandsDart = double Function(int, Pointer<Double>, Pointer<Double>);

typedef FfiCalculateMonthDensityNative = Double Function(Uint32, Uint32);
typedef FfiCalculateMonthDensityDart = double Function(int, int);

typedef FfiCalculateDragSnapNative = Uint8 Function(Double, Double, Uint8);
typedef FfiCalculateDragSnapDart = int Function(double, double, int);

// Phase 5: NLP Parser
final class CParseResult extends Struct {
  external Pointer<Utf8> clean_title;
  @Int64() external int start_time;
  @Int64() external int end_time;
  @Uint8() external int priority;
  external Pointer<Pointer<Utf8>> tags;
  @Size() external int tag_count;
  /// Date token: 0 none, 1 offset-days, 2 weekday, 3 explicit (y/m/d).
  @Uint8() external int date_kind;
  @Int64() external int date_a;
  @Int64() external int date_b;
  @Int64() external int date_c;
}

typedef FfiParseInputNative = CParseResult Function(Pointer<Utf8>);
typedef FfiParseInputDart = CParseResult Function(Pointer<Utf8>);

typedef FfiFreeParseResultNative = Void Function(CParseResult);
typedef FfiFreeParseResultDart = void Function(CParseResult);

typedef FfiCreateTaskExNative = Pointer<CTask> Function(
  Pointer<Utf8>, Int64, Int64, Int64, Uint8, Pointer<Pointer<Utf8>>, IntPtr,
);
typedef FfiCreateTaskExDart = Pointer<CTask> Function(
  Pointer<Utf8>, int, int, int, int, Pointer<Pointer<Utf8>>, int,
);

typedef FfiUpdateTaskExNative = Pointer<CTask> Function(
  Pointer<Utf8>, Pointer<Utf8>, Int64, Int64, Int64, Uint8, Pointer<Pointer<Utf8>>, IntPtr, Int32,
);
typedef FfiUpdateTaskExDart = Pointer<CTask> Function(
  Pointer<Utf8>, Pointer<Utf8>, int, int, int, int, Pointer<Pointer<Utf8>>, int, int,
);

typedef FfiRestoreTaskNative = Pointer<CTask> Function(
  Pointer<Utf8>, Int64, Int64, Int64, Uint8, Pointer<Pointer<Utf8>>, IntPtr, Int32, Int32, Int32,
);
typedef FfiRestoreTaskDart = Pointer<CTask> Function(
  Pointer<Utf8>, int, int, int, int, Pointer<Pointer<Utf8>>, int, int, int, int,
);

// ════════════════════════════════════════════════════════════════════════════
// SLATE CORE - MAIN FFI CLASS (PHASE 3)
// ════════════════════════════════════════════════════════════════════════════

class SlateCore {
  static final SlateCore _instance = SlateCore._internal();
  factory SlateCore() => _instance;
  
  DynamicLibrary? _lib;
  bool _ffiConnected = false;
  bool _engineInitialized = false;
  String _engineVersion = 'Dart Stub v3.0.0 (Phase 3)';


  /// True if connected to real Rust DLL
  bool get isFFIConnected => _ffiConnected;

  /// True if engine fully initialized (SQLite loaded, sync running)
  bool get isEngineReady => _engineInitialized;
  
  /// Engine version string
  String get engineVersion => _engineVersion;

  // ── Internal Dart fallback store (used when FFI not connected) ──
  List<RustTask> _fallbackTasks = [];
  
  SlateCore._internal() {
    _tryLoadLibrary();
  }
  
  /// Attempt to load the Rust DLL
  void _tryLoadLibrary() {
    try {
      final possiblePaths = [
        'slate_core.dll',
        'data/slate_core.dll',
        '${Directory.current.path}/slate_core.dll',
        '${Directory.current.path}/data/slate_core.dll',
      ];
      
      for (final path in possiblePaths) {
        try {
          _lib = DynamicLibrary.open(path);
          _ffiConnected = true;
          _loadFunctions();
          print('✓ FFI: Connected to Rust engine at $path');
          break;
        } catch (_) {
          continue;
        }
      }
      
      if (!_ffiConnected) {
        print('⚠ FFI: Using Dart stub (DLL not found)');
      }
    } catch (e) {
      print('⚠ FFI: Failed to load library: $e');
      _ffiConnected = false;
    }
  }
  
  // FFI function pointers (null if not connected)
  CalculateMagneticSnapDart? _ffiMagneticSnap;
  CalculateDayTransitionOpacityDart? _ffiDayTransition;
  FfiInitEngineDart? _ffiInitEngine;
  FfiShutdownEngineDart? _ffiShutdownEngine;
  FfiGetAllTasksDart? _ffiGetAllTasks;
  FfiRemoveTaskDart? _ffiRemoveTask;
  FfiCreateTaskDart? _ffiCreateTask;
  FfiCreateInboxTaskDart? _ffiCreateInboxTask;
  FfiToggleTaskDart? _ffiToggleTask;
  FfiTaskCountDart? _ffiTaskCount;
  FfiTasksForDateDart? _ffiTasksForDate;
  FfiFreeTaskDart? _ffiFreeTask;
  FfiFreeTaskListDart? _ffiFreeTaskList;
  
  // Phase 3 Spatial exports
  FfiCalculateFlowFrameDart? _ffiCalculateFlowFrame;
  FfiGenerateHourSlotsDart? _ffiGenerateHourSlots;
  FfiGenerateWeekCellsDart? _ffiGenerateWeekCells;
  FfiGenerateMonthCellsDart? _ffiGenerateMonthCells;
  FfiTaskCountsByHourDart? _ffiTaskCountsByHour;
  FfiTasksForHourDart? _ffiTasksForHour;
  FfiCalculateYearHeatmapDart? _ffiCalculateYearHeatmap;
  FfiCalculateSpringSnapDart? _ffiCalculateSpringSnap;
  FfiCalculateClockHandsDart? _ffiCalculateClockHands;
  FfiCalculateMonthDensityDart? _ffiCalculateMonthDensity;
  FfiCalculateDragSnapDart? _ffiCalculateDragSnap;

  // New list free functions
  FfiFreeDayCellListDart? _ffiFreeDayCellList;
  FfiFreeMonthCellListDart? _ffiFreeMonthCellList;
  FfiFreeHourSlotListDart? _ffiFreeHourSlotList;
  FfiFreeU32ListDart? _ffiFreeU32List;

  // Phase 5: NLP + Smart Day Input
  FfiParseInputDart? _ffiParseInput;
  FfiFreeParseResultDart? _ffiFreeParseResult;
  FfiCreateTaskExDart? _ffiCreateTaskEx;
  FfiUpdateTaskExDart? _ffiUpdateTaskEx;
  FfiRestoreTaskDart? _ffiRestoreTask;
  
  void _loadFunctions() {
    if (_lib == null) return;
    
    try {
      // Load health_check to verify connection and get version
      final healthCheck = _lib!.lookupFunction<HealthCheckNative, HealthCheckDart>('ffi_health_check');
      final versionPtr = healthCheck();
      _engineVersion = versionPtr.toDartString();
      
      // Load magnetic snap function
      _ffiMagneticSnap = _lib!.lookupFunction<CalculateMagneticSnapNative, CalculateMagneticSnapDart>('ffi_calculate_magnetic_snap');
      
      // Load day transition function
      _ffiDayTransition = _lib!.lookupFunction<CalculateDayTransitionOpacityNative, CalculateDayTransitionOpacityDart>('ffi_calculate_day_transition_opacity');
      
      // Phase 3: Engine init / shutdown + all tasks
      _ffiInitEngine = _lib!.lookupFunction<FfiInitEngineNative, FfiInitEngineDart>('ffi_init_engine');
      _ffiShutdownEngine = _lib!.lookupFunction<FfiShutdownEngineNative, FfiShutdownEngineDart>('ffi_shutdown_engine');
      _ffiGetAllTasks = _lib!.lookupFunction<FfiGetAllTasksNative, FfiGetAllTasksDart>('ffi_get_all_tasks');
      
      // Task store C-ABI bindings (live creation paths)
      _ffiRemoveTask = _lib!.lookupFunction<FfiRemoveTaskNative, FfiRemoveTaskDart>('ffi_remove_task');
      _ffiCreateTask = _lib!.lookupFunction<FfiCreateTaskNative, FfiCreateTaskDart>('ffi_create_task');
      _ffiCreateInboxTask = _lib!.lookupFunction<FfiCreateInboxTaskNative, FfiCreateInboxTaskDart>('ffi_create_inbox_task');
      _ffiToggleTask = _lib!.lookupFunction<FfiToggleTaskNative, FfiToggleTaskDart>('ffi_toggle_task');
      _ffiTaskCount = _lib!.lookupFunction<FfiTaskCountNative, FfiTaskCountDart>('ffi_task_count');
      _ffiTasksForDate = _lib!.lookupFunction<FfiTasksForDateNative, FfiTasksForDateDart>('ffi_tasks_for_date');
      _ffiFreeTask = _lib!.lookupFunction<FfiFreeTaskNative, FfiFreeTaskDart>('ffi_free_task');
      _ffiFreeTaskList = _lib!.lookupFunction<FfiFreeTaskListNative, FfiFreeTaskListDart>('ffi_free_task_list');
      
      _ffiCalculateFlowFrame = _lib!.lookupFunction<FfiCalculateFlowFrameNative, FfiCalculateFlowFrameDart>('ffi_calculate_flow_frame');
      _ffiGenerateHourSlots = _lib!.lookupFunction<FfiGenerateHourSlotsNative, FfiGenerateHourSlotsDart>('ffi_generate_hour_slots');
      _ffiGenerateWeekCells = _lib!.lookupFunction<FfiGenerateWeekCellsNative, FfiGenerateWeekCellsDart>('ffi_generate_week_cells');
      _ffiGenerateMonthCells = _lib!.lookupFunction<FfiGenerateMonthCellsNative, FfiGenerateMonthCellsDart>('ffi_generate_month_cells');
      _ffiTaskCountsByHour = _lib!.lookupFunction<FfiTaskCountsByHourNative, FfiTaskCountsByHourDart>('ffi_task_counts_by_hour');
      _ffiTasksForHour = _lib!.lookupFunction<FfiTasksForHourNative, FfiTasksForHourDart>('ffi_tasks_for_hour');
      _ffiCalculateYearHeatmap = _lib!.lookupFunction<FfiCalculateYearHeatmapNative, FfiCalculateYearHeatmapDart>('ffi_calculate_year_heatmap');
      _ffiCalculateSpringSnap = _lib!.lookupFunction<FfiCalculateSpringSnapNative, FfiCalculateSpringSnapDart>('ffi_calculate_spring_snap');
      _ffiCalculateClockHands = _lib!.lookupFunction<FfiCalculateClockHandsNative, FfiCalculateClockHandsDart>('ffi_calculate_clock_hands');
      _ffiCalculateMonthDensity = _lib!.lookupFunction<FfiCalculateMonthDensityNative, FfiCalculateMonthDensityDart>('ffi_calculate_month_density');
      _ffiCalculateDragSnap = _lib!.lookupFunction<FfiCalculateDragSnapNative, FfiCalculateDragSnapDart>('ffi_calculate_drag_snap');

      // Bind structural free functions
      _ffiFreeDayCellList = _lib!.lookupFunction<FfiFreeDayCellListNative, FfiFreeDayCellListDart>('ffi_free_day_cell_list');
      _ffiFreeMonthCellList = _lib!.lookupFunction<FfiFreeMonthCellListNative, FfiFreeMonthCellListDart>('ffi_free_month_cell_list');
      _ffiFreeHourSlotList = _lib!.lookupFunction<FfiFreeHourSlotListNative, FfiFreeHourSlotListDart>('ffi_free_hour_slot_list');
      _ffiFreeU32List = _lib!.lookupFunction<FfiFreeU32ListNative, FfiFreeU32ListDart>('ffi_free_u32_list');

      // Phase 5: NLP Parser + Smart Day Input
      _ffiParseInput = _lib!.lookupFunction<FfiParseInputNative, FfiParseInputDart>('ffi_parse_input');
      _ffiFreeParseResult = _lib!.lookupFunction<FfiFreeParseResultNative, FfiFreeParseResultDart>('ffi_free_parse_result');
      _ffiCreateTaskEx = _lib!.lookupFunction<FfiCreateTaskExNative, FfiCreateTaskExDart>('ffi_create_task_ex');
      _ffiUpdateTaskEx = _lib!.lookupFunction<FfiUpdateTaskExNative, FfiUpdateTaskExDart>('ffi_update_task_ex');
      _ffiRestoreTask = _lib!.lookupFunction<FfiRestoreTaskNative, FfiRestoreTaskDart>('ffi_restore_task');
      
    } catch (e) {
      print('⚠ FFI: Function binding failed: $e');
      _ffiConnected = false;
    }
  }
  
  /// Health check - returns version string
  String healthCheck() {
    return _engineVersion;
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PHASE 3: ENGINE INITIALIZATION
  // ════════════════════════════════════════════════════════════════════════════

  /// Initialize the offline engine.
  /// Rust opens SQLite, loads tasks, spawns sync worker.
  /// Returns the number of tasks loaded from local DB, or -1 on error.
  int initEngine({
    required String dbPath,
    required String supabaseUrl,
    required String supabaseKey,
    required String dbKey,
  }) {
    if (_ffiConnected && _ffiInitEngine != null) {
      return using((Arena arena) {
        final dbPathPtr = _safeCString(dbPath, arena);
        final urlPtr = _safeCString(supabaseUrl, arena);
        final keyPtr = _safeCString(supabaseKey, arena);
        final dbKeyPtr = _safeCString(dbKey, arena);

        final result = _ffiInitEngine!(dbPathPtr, urlPtr, keyPtr, dbKeyPtr);

        if (result >= 0) {
          _engineInitialized = true;
          print('✓ Engine initialized: $result tasks from local DB');
        }
        return result;
      }); // Arena auto-frees all pointers here, even on exception
    }
    
    // Dart fallback: no local DB, just use in-memory
    _engineInitialized = true;
    return _fallbackTasks.length;
  }

  /// Graceful shutdown — stops the Rust sync worker, flushes any pending DB
  /// writes and checkpoints the WAL. Called from the window-close handler.
  void shutdownEngine() {
    if (_ffiConnected && _ffiShutdownEngine != null) {
      _ffiShutdownEngine!();
    }
  }

  /// Calculate flow layout frame.
  SpatialFrame calculateFlowFrame({
    required int selectedDateTs,
    required double viewportWidth,
    required double scrollOffset,
  }) {
    if (_ffiConnected && _ffiCalculateFlowFrame != null) {
      final frame = _ffiCalculateFlowFrame!(selectedDateTs, viewportWidth, scrollOffset);
      return SpatialFrame(
        visibleStartHour: (frame.visibleStart / 3600000).floor(),
        visibleEndHour: (frame.visibleEnd / 3600000).ceil(),
        hourWidth: frame.hourWidth,
        currentOffset: frame.currentOffset,
        totalWidth: frame.totalWidth,
      );
    }
    // Fallback stub
    return SpatialFrame(
      visibleStartHour: 0,
      visibleEndHour: 24,
      hourWidth: 60.0,
      currentOffset: scrollOffset,
      totalWidth: 60.0 * 24,
    );
  }

  /// Bootstrap the Dart fallback task list (legacy Phase 2 compat).
  /// On the live FFI path, the Rust engine loads tasks from SQLite via ffi_init_engine.
  /// This method only updates the in-memory fallback for the non-FFI stub path.
  void initTaskStore(List<RustTask> tasks) {
    _fallbackTasks = List.of(tasks);
    // No JSON FFI path — ffi_init_task_store is a deprecated JSON endpoint.
    // The authoritative init path is initEngine() → ffi_init_engine() → SQLite load.
  }

  /// Add a single task to the Rust store.
  /// NOTE: This method now only updates the Dart fallback list.
  /// The live FFI path uses ffi_create_task() / ffi_create_task_ex() directly.
  void addTaskToStore(RustTask task) {
    _fallbackTasks.insert(0, task);
    // No JSON FFI path — ffi_add_task is a deprecated JSON endpoint.
    // Task mutations go through ffi_create_task / ffi_create_task_ex / ffi_toggle_task.
  }

  /// Update a task in the Rust store (remove + re-insert with new data).
  /// NOTE: Fallback-only path. Live mutations use ffi_toggle_task / ffi_create_task_ex.
  void updateTaskInStore(RustTask task) {
    final idx = _fallbackTasks.indexWhere((t) => t.id == task.id);
    if (idx != -1) _fallbackTasks[idx] = task;

    // Real in-place update through Rust: mutate the existing task (title, assigned day,
    // start/end time, priority, tags) and persist. This REPLACES the old "remove without
    // re-insert" path that deleted the task from the store on every edit — that bug made
    // edited tasks vanish from both the list and the timeline (#15a).
    // Zero-Copy: tag strings + pointer array allocated in an Arena, freed on scope exit.
    if (_ffiConnected && _ffiUpdateTaskEx != null && _ffiFreeTask != null) {
      using((Arena arena) {
        final idPtr = _safeCString(task.id, arena);
        final titlePtr = _safeCString(task.title, arena);
        final tagPtrs = arena<Pointer<Utf8>>(task.tags.length);
        for (int i = 0; i < task.tags.length; i++) {
          tagPtrs[i] = _safeCString(task.tags[i], arena);
        }
        final cTaskPtr = _ffiUpdateTaskEx!(
          idPtr,
          titlePtr,
          task.createdAt,          // assigned-day midnight ms (Rust reindexes by day)
          task.startTime ?? -1,    // -1 → unscheduled (no intra-day time)
          task.endTime ?? -1,
          task.priority,
          tagPtrs.cast<Pointer<Utf8>>(),
          task.tags.length,
          task.isInbox ? 1 : 0,
        );
        // Caller-Frees: release the returned task struct (Dart already holds the edit).
        if (cTaskPtr != nullptr) {
          _ffiFreeTask!(cTaskPtr);
        }
      });
    }
  }

  /// Remove a task from the Rust store by ID. Returns the task's position in
  /// its day list (-1 if unknown) — the undo snapshot restores it there.
  int removeTaskFromStore(String taskId) {
    final fallbackIdx = _fallbackTasks.indexWhere((t) => t.id == taskId);
    _fallbackTasks.removeWhere((t) => t.id == taskId);
    if (_ffiConnected && _ffiRemoveTask != null) {
      return using((Arena arena) {
        final idPtr = _safeCString(taskId, arena);
        return _ffiRemoveTask!(idPtr);
      });
    }
    return fallbackIdx;
  }

  /// Undo path: rebuild a deleted task in one call — full state (done, inbox,
  /// tags, priority, times, ORIGINAL createdAt) at its original day position.
  RustTask? restoreTask(RustTask snapshot, int dayIndex) {
    if (_ffiConnected && _ffiRestoreTask != null && _ffiFreeTask != null) {
      final restored = using((Arena arena) {
        final titlePtr = _safeCString(snapshot.title, arena);
        final tagPtrs = arena<Pointer<Utf8>>(snapshot.tags.length);
        for (int i = 0; i < snapshot.tags.length; i++) {
          tagPtrs[i] = _safeCString(snapshot.tags[i], arena);
        }
        final cTaskPtr = _ffiRestoreTask!(
          titlePtr,
          snapshot.createdAt,
          snapshot.startTime ?? -1,
          snapshot.endTime ?? -1,
          snapshot.priority,
          tagPtrs.cast<Pointer<Utf8>>(),
          snapshot.tags.length,
          snapshot.isInbox ? 1 : 0,
          snapshot.isCompleted ? 1 : 0,
          dayIndex < 0 ? 0 : dayIndex,
        );
        if (cTaskPtr != nullptr) {
          try {
            final task = _cTaskToRustTask(cTaskPtr.ref);
            _fallbackTasks.insert(0, task);
            return task;
          } finally {
            _ffiFreeTask!(cTaskPtr);
          }
        }
        return null;
      });
      if (restored != null) return restored;
    }

    // Dart fallback (stub engine): keep the snapshot with a fresh id.
    final task = snapshot.copyWith(
        id: _generateUUID(),
        updatedAt: DateTime.now().millisecondsSinceEpoch);
    _fallbackTasks.insert(dayIndex.clamp(0, _fallbackTasks.length), task);
    return task;
  }

  /// Get task count from Rust store.
  int getTaskCount() {
    if (_ffiConnected && _ffiTaskCount != null) {
      return _ffiTaskCount!();
    }
    return _fallbackTasks.length;
  }

  /// Get all tasks from Rust store.
  List<RustTask> getAllTasks() {
    if (_ffiConnected && _ffiGetAllTasks != null && _ffiFreeTaskList != null) {
      final taskList = _ffiGetAllTasks!();
      try {
        final List<RustTask> tasks = [];
        for (var i = 0; i < taskList.len; i++) {
          tasks.add(_cTaskToRustTask(taskList.data[i]));
        }
        return tasks;
      } finally {
        _ffiFreeTaskList!(taskList);
      }
    }
    return List.of(_fallbackTasks);
  }


  /// Maximum string length allowed through FFI (defense against buffer overflow).
  static const int _maxFfiStringLen = 10000;

  /// Safely convert a Dart string to a C string with length validation.
  /// Uses the provided [allocator] (typically an Arena) for automatic cleanup.
  Pointer<Utf8> _safeCString(String str, Allocator allocator) {
    final safe = str.length > _maxFfiStringLen
        ? str.substring(0, _maxFfiStringLen)
        : str;
    return safe.toNativeUtf8(allocator: allocator);
  }
  
  // ════════════════════════════════════════════════════════════════════════════
  // SPATIAL CALCULATIONS
  // ════════════════════════════════════════════════════════════════════════════
  
  /// Generate hour slots for visible range
  List<HourSlot> generateHourSlots({
    required int selectedDateTs,
    required double viewportWidth,
    required double scrollOffset,
    required List<int> taskCounts,
  }) {
    if (_ffiConnected && _ffiGenerateHourSlots != null && _ffiFreeHourSlotList != null) {
      final ptrCounts = calloc<Uint32>(taskCounts.length);
      for (int i = 0; i < taskCounts.length; i++) {
        ptrCounts[i] = taskCounts[i];
      }
      final list = _ffiGenerateHourSlots!(selectedDateTs, viewportWidth, scrollOffset, ptrCounts, taskCounts.length);
      calloc.free(ptrCounts);
      
      try {
        final result = <HourSlot>[];
        for (int i = 0; i < list.len; i++) {
          final slot = list.data[i];
          result.add(HourSlot(
            hour: slot.hour,
            xOffset: slot.xOffset,
            isCurrent: slot.isCurrent,
            taskCount: slot.taskCount,
          ));
        }
        return result;
      } finally {
        _ffiFreeHourSlotList!(list);
      }
    }
    return [];
  }
  
  /// Zero-copy decode: Week cells
  List<DayCell> generateWeekCells(int currentDateTs) {
    if (_ffiConnected && _ffiGenerateWeekCells != null && _ffiFreeDayCellList != null) {
      final list = _ffiGenerateWeekCells!(currentDateTs);
      try {
        final result = <DayCell>[];
        for (int i = 0; i < list.len; i++) {
          final dataMap = list.data[i];
          result.add(DayCell(
            dateTimestamp: dataMap.dateTimestamp,
            dayOfWeek: dataMap.dayOfWeek,
            dayOfMonth: dataMap.dayOfMonth,
            isToday: dataMap.isToday,
            taskCount: dataMap.taskCount,
            completedCount: dataMap.completedCount,
          ));
        }
        return result;
      } finally {
        _ffiFreeDayCellList!(list);
      }
    }
    return [];
  }

  /// Zero-copy decode: Month cells
  List<DayCell?> generateMonthCells(int year, int month) {
    if (_ffiConnected && _ffiGenerateMonthCells != null && _ffiFreeMonthCellList != null) {
      final list = _ffiGenerateMonthCells!(year, month);
      try {
        final result = <DayCell?>[];
        for (int i = 0; i < list.len; i++) {
          final optCell = list.data[i];
          if (optCell.isValid == 1) {
            final dataMap = optCell.cell;
            result.add(DayCell(
              dateTimestamp: dataMap.dateTimestamp,
              dayOfWeek: dataMap.dayOfWeek,
              dayOfMonth: dataMap.dayOfMonth,
              isToday: dataMap.isToday,
              taskCount: dataMap.taskCount,
              completedCount: dataMap.completedCount,
            ));
          } else {
            result.add(null);
          }
        }
        return result;
      } finally {
        _ffiFreeMonthCellList!(list);
      }
    }
    return List.filled(42, null);
  }
  
  /// Calculate magnetic snap for day boundaries
  double calculateMagneticSnap({
    required double scrollOffset,
    required double velocity,
    required double dayBoundaryOffset,
  }) {
    if (_ffiConnected && _ffiMagneticSnap != null) {
      return _ffiMagneticSnap!(scrollOffset, velocity, dayBoundaryOffset);
    }
    
    final distance = (scrollOffset - dayBoundaryOffset).abs();
    const snapThreshold = 80.0;
    const snapStrength = 0.15;
    
    if (distance < snapThreshold && velocity.abs() < 100.0) {
      final pull = (snapThreshold - distance) * snapStrength;
      return scrollOffset < dayBoundaryOffset
          ? scrollOffset + pull
          : scrollOffset - pull;
    }
    return scrollOffset;
  }
  
  /// Count tasks per hour for a date.
  List<int> taskCountsByHour(int dateTs) {
    if (_ffiConnected && _ffiTaskCountsByHour != null && _ffiFreeU32List != null) {
      final list = _ffiTaskCountsByHour!(dateTs);
      try {
        final result = <int>[];
        for (int i = 0; i < list.len; i++) {
          result.add(list.data[i]);
        }
        return result;
      } finally {
        _ffiFreeU32List!(list);
      }
    }
    return List.filled(24, 0);
  }
  
  /// Filter tasks for a specific date.
  List<RustTask> tasksForDate(int dateTs) {
    if (_ffiConnected && _ffiTasksForDate != null) {
      return _ffiGetTasksForDate(dateTs);
    }
    
    final targetDate = DateTime.fromMillisecondsSinceEpoch(dateTs);
    return _fallbackTasks.where((t) {
      final taskDate = DateTime.fromMillisecondsSinceEpoch(t.createdAt);
      return taskDate.day == targetDate.day && 
             taskDate.month == targetDate.month && 
             taskDate.year == targetDate.year;
    }).toList();
  }
  
  /// Filter tasks for a specific hour on a date.
  List<RustTask> tasksForHour(int dateTs, int hour) {
    if (_ffiConnected && _ffiTasksForHour != null && _ffiFreeTaskList != null) {
      final taskList = _ffiTasksForHour!(dateTs, hour);
      try {
        final List<RustTask> tasks = [];
        for (var i = 0; i < taskList.len; i++) {
          tasks.add(_cTaskToRustTask(taskList.data[i]));
        }
        return tasks;
      } finally {
        _ffiFreeTaskList!(taskList);
      }
    }
    return [];
  }

  /// Internal FFI helper: get tasks for a date from Rust store via JSON.
  List<RustTask> _ffiGetTasksForDate(int dateTs) {
    if (_ffiFreeTaskList == null) return [];
    final taskList = _ffiTasksForDate!(dateTs);
    try {
      final List<RustTask> tasks = [];
      for (var i = 0; i < taskList.len; i++) {
        tasks.add(_cTaskToRustTask(taskList.data[i]));
      }
      return tasks;
    } finally {
      _ffiFreeTaskList!(taskList);
    }
  }
  
  // ════════════════════════════════════════════════════════════════════════════
  // TASK MUTATIONS
  // ════════════════════════════════════════════════════════════════════════════
  
  /// Toggle task completion status via Rust (SQLite + Sync Queue)
  RustTask toggleTask(RustTask task) {
    if (_ffiConnected && _ffiToggleTask != null && _ffiFreeTask != null) {
      final toggled = using((Arena arena) {
        final idPtr = _safeCString(task.id, arena);
        final cTaskPtr = _ffiToggleTask!(idPtr);

        if (cTaskPtr != nullptr) {
          try {
            final result = _cTaskToRustTask(cTaskPtr.ref);
            final idx = _fallbackTasks.indexWhere((t) => t.id == task.id);
            if (idx != -1) _fallbackTasks[idx] = result;
            return result;
          } finally {
            _ffiFreeTask!(cTaskPtr);
          }
        }
        return null;
      });
      if (toggled != null) return toggled;
    }

    // Fallback path: copyWith preserves EVERY field (the old hand-built
    // constructor silently dropped isInbox/startTime/endTime/priority/tags).
    final toggled = task.copyWith(
      isCompleted: !task.isCompleted,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    // Sync to Rust store (which also persists to SQLite + queues sync)
    updateTaskInStore(toggled);
    return toggled;
  }
  
  /// Create a new task with proper UUID via Rust (SQLite + Sync Queue)
  RustTask createTask(String title, int nowTs) {
    if (_ffiConnected && _ffiCreateTask != null && _ffiFreeTask != null) {
      final created = using((Arena arena) {
        final titlePtr = _safeCString(title, arena);
        final cTaskPtr = _ffiCreateTask!(titlePtr, nowTs);

        if (cTaskPtr != nullptr) {
          try {
            final task = _cTaskToRustTask(cTaskPtr.ref);
            _fallbackTasks.insert(0, task);
            return task;
          } finally {
            _ffiFreeTask!(cTaskPtr);
          }
        }
        return null;
      });
      if (created != null) return created;
    }

    final uuid = _generateUUID();
    final now = DateTime.now().millisecondsSinceEpoch;
    final task = RustTask(
      id: uuid,
      title: title,
      isCompleted: false,
      createdAt: nowTs,
      updatedAt: now,
      isInbox: false,
    );
    addTaskToStore(task);
    return task;
  }

  /// Create a new Inbox task via Rust (is_inbox = true, SQLite + Sync Queue)
  RustTask createInboxTask(String title, int nowTs) {
    if (_ffiConnected && _ffiCreateInboxTask != null && _ffiFreeTask != null) {
      final created = using((Arena arena) {
        final titlePtr = _safeCString(title, arena);
        final cTaskPtr = _ffiCreateInboxTask!(titlePtr, nowTs);

        if (cTaskPtr != nullptr) {
          try {
            final task = _cTaskToRustTask(cTaskPtr.ref);
            _fallbackTasks.insert(0, task);
            return task;
          } finally {
            _ffiFreeTask!(cTaskPtr);
          }
        }
        return null;
      });
      if (created != null) return created;
    }

    // Dart fallback
    final uuid = _generateUUID();
    final now = DateTime.now().millisecondsSinceEpoch;
    final task = RustTask(
      id: uuid,
      title: title,
      isCompleted: false,
      createdAt: nowTs,
      updatedAt: now,
      isInbox: true,
    );
    addTaskToStore(task);
    return task;
  }
  
  String _generateUUID() {
    final rng = _secureRng;
    String hex(int len) {
      const chars = '0123456789abcdef';
      final buf = StringBuffer();
      for (int i = 0; i < len; i++) {
        buf.write(chars[rng.nextInt(16)]);
      }
      return buf.toString();
    }
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${['8','9','a','b'][rng.nextInt(4)]}${hex(3)}-${hex(12)}';
  }
  static final _secureRng = Random.secure();
  
  // ════════════════════════════════════════════════════════════════════════════
  // SPRING PHYSICS
  // ════════════════════════════════════════════════════════════════════════════
  
  SpringSnapResult calculateSpringSnap({
    required double scrollOffset,
    required double velocity,
    required double dayBoundaryOffset,
    required double dt,
  }) {
    if (_ffiConnected && _ffiCalculateSpringSnap != null) {
      final outOffset = calloc<Double>();
      final newVelocity = _ffiCalculateSpringSnap!(scrollOffset, velocity, dayBoundaryOffset, dt, outOffset);
      final newOffset = outOffset.value;
      calloc.free(outOffset);
      return SpringSnapResult(newOffset, newVelocity);
    }
    return SpringSnapResult(scrollOffset, velocity);
  }
  
  /// Calculate fade opacity for next-day transition
  double calculateDayTransitionOpacity(double scrollOffset, double dayBoundary) {
    if (_ffiConnected && _ffiDayTransition != null) {
      return _ffiDayTransition!(scrollOffset, dayBoundary);
    }
    
    const transitionZone = 200.0;
    final distancePastBoundary = scrollOffset - dayBoundary;
    
    if (distancePastBoundary < 0) return 0.0;
    if (distancePastBoundary > transitionZone) return 1.0;
    return distancePastBoundary / transitionZone;
  }
  
  // ════════════════════════════════════════════════════════════════════════════
  // STRATEGY HEATMAP & SWEEPING CLOCK
  // ════════════════════════════════════════════════════════════════════════════
  
  ClockHandAngles calculateClockHandAngles(int nowMs) {
    if (_ffiConnected && _ffiCalculateClockHands != null) {
      final outHour = calloc<Double>();
      final outMinute = calloc<Double>();
      final secondDeg = _ffiCalculateClockHands!(nowMs, outHour, outMinute);
      final hourDeg = outHour.value;
      final minuteDeg = outMinute.value;
      calloc.free(outHour);
      calloc.free(outMinute);
      return ClockHandAngles(hourDeg, minuteDeg, secondDeg);
    }
    return ClockHandAngles(0, 0, 0);
  }
  
  double calculateMonthDensity(int taskCount, int maxExpected) {
    if (_ffiConnected && _ffiCalculateMonthDensity != null) {
      return _ffiCalculateMonthDensity!(taskCount, maxExpected);
    }
    return 0.0;
  }
  
  /// Calculate year heatmap — task counts per month.
  List<int> calculateYearHeatmap(int year) {
    if (_ffiConnected && _ffiCalculateYearHeatmap != null && _ffiFreeU32List != null) {
      final list = _ffiCalculateYearHeatmap!(year);
      try {
        final result = <int>[];
        for (int i = 0; i < list.len; i++) {
          result.add(list.data[i]);
        }
        return result;
      } finally {
        _ffiFreeU32List!(list);
      }
    }
    return List.filled(12, 0);
  }
  
  int calculateDragSnap(double dragX, double columnWidth, int numDays) {
    if (_ffiConnected && _ffiCalculateDragSnap != null) {
      return _ffiCalculateDragSnap!(dragX, columnWidth, numDays);
    }
    return 0;
  }
  
  RustTask _cTaskToRustTask(CTask ctask) {
    // Zero-copy tag decode: walk the pointer array directly — no JSON, no string parsing.
    final tags = <String>[];
    if (ctask.tags != nullptr && ctask.tag_count > 0) {
      for (int i = 0; i < ctask.tag_count; i++) {
        final tagPtr = ctask.tags[i];
        if (tagPtr != nullptr) {
          tags.add(tagPtr.toDartString());
        }
      }
    }

    return RustTask(
      id: ctask.id.toDartString(),
      title: ctask.title.toDartString(),
      isCompleted: ctask.isCompleted,
      isInbox: ctask.isInbox,
      createdAt: ctask.created_at,
      updatedAt: ctask.updated_at != 0 ? ctask.updated_at : ctask.created_at,
      startAt: ctask.start_at == 0 ? null : ctask.start_at,
      endAt: ctask.end_at == 0 ? null : ctask.end_at,
      userId: null,
      startTime: ctask.start_time < 0 ? null : ctask.start_time,
      endTime: ctask.end_time < 0 ? null : ctask.end_time,
      priority: ctask.priority,
      tags: tags,
    );
  }

  // ════════════════════════════════════════════════════════════════════════════
  // PHASE 5: SMART DAY INPUT — NLP + WIPE + EXTENDED CREATE
  // ════════════════════════════════════════════════════════════════════════════

  /// Parse raw input string via Rust NLP engine.
  /// Returns structured result with cleaned title, time, priority, and tags.
  ParseResult parseInput(String raw) {
    if (_ffiConnected && _ffiParseInput != null && _ffiFreeParseResult != null) {
      final result = using((Arena arena) {
        final rawPtr = _safeCString(raw, arena);
        return _ffiParseInput!(rawPtr);
      });

      try {
        final cleanTitle = result.clean_title != nullptr
            ? result.clean_title.toDartString()
            : '';
        final tags = <String>[];
        if (result.tags != nullptr && result.tag_count > 0) {
          for (int i = 0; i < result.tag_count; i++) {
            final tagPtr = result.tags[i];
            if (tagPtr != nullptr) {
              tags.add(tagPtr.toDartString());
            }
          }
        }
        return ParseResult(
          cleanTitle: cleanTitle,
          startTime: result.start_time >= 0 ? result.start_time : null,
          endTime: result.end_time >= 0 ? result.end_time : null,
          priority: result.priority,
          tags: tags,
          dateKind: result.date_kind,
          dateA: result.date_a,
          dateB: result.date_b,
          dateC: result.date_c,
        );
      } finally {
        _ffiFreeParseResult!(result);
      }
    }
    // Dart fallback: no parsing, just return raw text
    return ParseResult(cleanTitle: raw);
  }

  /// Create a task with NLP-parsed fields (Phase 5 Smart Day Input).
  /// Zero-Copy: allocates a native tag pointer array via calloc, passes it raw to Rust.
  /// Caller-Frees: the input tags array is freed in this method's finally block.
  RustTask createTaskEx({
    required String title,
    required int dayTs,
    int? startTime,
    int? endTime,
    int priority = 0,
    List<String> tags = const [],
  }) {
    if (_ffiConnected && _ffiCreateTaskEx != null && _ffiFreeTask != null) {
      final created = using((Arena arena) {
        final titlePtr = _safeCString(title, arena);

        // Allocate a native array of Pointer<Utf8> for tags (zero JSON, raw C strings).
        // Arena auto-frees all allocations (title, tag strings, pointer array) on exit.
        final tagPtrs = arena<Pointer<Utf8>>(tags.length);
        for (int i = 0; i < tags.length; i++) {
          tagPtrs[i] = _safeCString(tags[i], arena);
        }

        final cTaskPtr = _ffiCreateTaskEx!(
          titlePtr,
          dayTs,
          startTime ?? -1,
          endTime ?? -1,
          priority,
          tagPtrs.cast<Pointer<Utf8>>(),
          tags.length,
        );

        if (cTaskPtr != nullptr) {
          try {
            final task = _cTaskToRustTask(cTaskPtr.ref);
            _fallbackTasks.insert(0, task);
            return task;
          } finally {
            _ffiFreeTask!(cTaskPtr);
          }
        }
        return null;
      });
      if (created != null) return created;
    }

    // Dart fallback (no FFI connection)
    final uuid = _generateUUID();
    final now = DateTime.now().millisecondsSinceEpoch;
    final task = RustTask(
      id: uuid,
      title: title,
      isCompleted: false,
      createdAt: dayTs,
      updatedAt: now,
      isInbox: false,
      startTime: startTime,
      endTime: endTime,
      priority: priority,
      tags: tags,
    );
    addTaskToStore(task);
    return task;
  }
}

// Use standard calloc from package:ffi instead of custom MSVCRT bindings

// ════════════════════════════════════════════════════════════════════════════
// FFI TYPES
// ════════════════════════════════════════════════════════════════════════════

class SpatialFrame {
  final int visibleStartHour;
  final int visibleEndHour;
  final double hourWidth;
  final double currentOffset;
  final double totalWidth;
  
  SpatialFrame({
    required this.visibleStartHour,
    required this.visibleEndHour,
    required this.hourWidth,
    required this.currentOffset,
    required this.totalWidth,
  });
}

class HourSlot {
  final int hour;
  final double xOffset;
  final bool isCurrent;
  final int taskCount;
  
  HourSlot({
    required this.hour,
    required this.xOffset,
    required this.isCurrent,
    required this.taskCount,
  });
}

class DayCell {
  final int dateTimestamp;
  final int dayOfWeek;
  final int dayOfMonth;
  final bool isToday;
  int taskCount;
  int completedCount;
  
  DayCell({
    required this.dateTimestamp,
    required this.dayOfWeek,
    required this.dayOfMonth,
    required this.isToday,
    required this.taskCount,
    required this.completedCount,
  });
}

class RustTask {
  final String id;
  final String title;
  final bool isCompleted;
  final int createdAt;
  final int updatedAt;  // Phase 3: LWW timestamp
  final int? startAt;
  final int? endAt;
  final String? userId;
  /// Phase 4: true = lives in Inbox (never on calendar)
  final bool isInbox;
  /// Phase 5: Intra-day start time (minutes since midnight)
  final int? startTime;
  /// Phase 5: Intra-day end time (minutes since midnight)
  final int? endTime;
  /// Phase 5: Priority level (0=Normal, 1=Important, 2=Very Important)
  final int priority;
  /// Phase 5: Custom tags
  final List<String> tags;

  /// Phase 5: Whether this task has been allocated to a specific time slot
  bool get isAllocated => startTime != null;

  RustTask({
    required this.id,
    required this.title,
    required this.isCompleted,
    required this.createdAt,
    int? updatedAt,
    this.startAt,
    this.endAt,
    this.userId,
    this.isInbox = false,
    this.startTime,
    this.endTime,
    this.priority = 0,
    this.tags = const [],
  }) : updatedAt = updatedAt ?? createdAt;

  factory RustTask.fromTask(dynamic task) {
    return RustTask(
      id: task.id,
      title: task.title,
      isCompleted: task.isCompleted,
      createdAt: task.createdAt.millisecondsSinceEpoch,
      updatedAt: task.updatedAt.millisecondsSinceEpoch,
      startAt: task.startAt?.millisecondsSinceEpoch,
      endAt: task.endAt?.millisecondsSinceEpoch,
      userId: task.userId,
      isInbox: task.isInbox ?? false,
    );
  }

  RustTask copyWith({
    String? id,
    String? title,
    bool? isCompleted,
    int? createdAt,
    int? updatedAt,
    int? startAt,
    int? endAt,
    String? userId,
    bool? isInbox,
    int? startTime,
    int? endTime,
    int? priority,
    List<String>? tags,
  }) {
    return RustTask(
      id: id ?? this.id,
      title: title ?? this.title,
      isCompleted: isCompleted ?? this.isCompleted,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      startAt: startAt ?? this.startAt,
      endAt: endAt ?? this.endAt,
      userId: userId ?? this.userId,
      isInbox: isInbox ?? this.isInbox,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      priority: priority ?? this.priority,
      tags: tags ?? this.tags,
    );
  }

  /// Serialize to JSON map for FFI transfer to Rust.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'is_completed': isCompleted,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'start_at': startAt,
    'end_at': endAt,
    'user_id': userId,
    'is_inbox': isInbox,
    'start_time': startTime,
    'end_time': endTime,
    'priority': priority,
    'tags': tags,
  };
}

/// Phase 5: Result from NLP parser
class ParseResult {
  final String cleanTitle;
  final int? startTime;  // minutes since midnight
  final int? endTime;    // minutes since midnight
  final int priority;    // 0/1/2
  final List<String> tags;
  /// Date token: 0 none, 1 offset-days, 2 weekday, 3 explicit (y/m/d).
  /// Resolution to a concrete day lives in capture_destination.dart.
  final int dateKind;
  final int dateA;
  final int dateB;
  final int dateC;

  const ParseResult({
    this.cleanTitle = '',
    this.startTime,
    this.endTime,
    this.priority = 0,
    this.tags = const [],
    this.dateKind = 0,
    this.dateA = -1,
    this.dateB = -1,
    this.dateC = -1,
  });

  bool get hasTime => startTime != null;
  bool get hasTags => tags.isNotEmpty;
  bool get hasPriority => priority > 0;
  bool get hasDate => dateKind != 0;

  /// Format start_time as HH:MM string.
  String? get startTimeFormatted {
    if (startTime == null) return null;
    final h = startTime! ~/ 60;
    final m = startTime! % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// Format end_time as HH:MM string.
  String? get endTimeFormatted {
    if (endTime == null) return null;
    final h = endTime! ~/ 60;
    final m = endTime! % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }
}

/// A ghost/repeating task
class GhostTask {
  final RustTask task;
  GhostTask({required this.task});
}

class SpringSnapResult {
  final double offset;
  final double velocity;
  
  SpringSnapResult(this.offset, this.velocity);
}

/// Clock hand angles for smooth sweeping display
class ClockHandAngles {
  final double hourDeg;
  final double minuteDeg;
  final double secondDeg;
  
  ClockHandAngles(this.hourDeg, this.minuteDeg, this.secondDeg);
}
