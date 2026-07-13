import 'package:flutter/foundation.dart';
import '../engine/spatial_zoom_engine.dart';
import 'local_prefs.dart';

/// First-run arc, one place:
///   welcome overlay → user's FIRST capture (any path: global pill, day pill,
///   inbox input) → confirm moment ("tucked into …") → done forever.
/// Ghost hints in empty states live until that same first capture.
class FirstRunController {
  FirstRunController._();
  static final FirstRunController instance = FirstRunController._();

  /// Where the first capture landed ("Inbox", "Today 14:00", …). The welcome
  /// overlay listens and plays its confirm moment; null until it happens.
  final ValueNotifier<String?> firstLanding = ValueNotifier(null);

  /// Mirrors StaircaseState.isFirstRun reactively so hint widgets can fade
  /// out live the moment the first capture lands.
  final ValueNotifier<bool> hintsActive = ValueNotifier(false);

  /// True while demo tasks are being seeded — a seed is not a user capture.
  bool muted = false;

  void syncFromPrefs() {
    hintsActive.value = StaircaseState.isFirstRun;
  }

  /// Any successful capture calls this. First one completes the whole arc.
  void recordCapture(String label) {
    if (muted || !StaircaseState.isFirstRun) return;
    StaircaseState.isFirstRun = false;
    // Unmounted welcome (capture from the tray pill) must not return later.
    StaircaseState.showWelcome = false;
    hintsActive.value = false;
    try {
      LocalPrefs.instance
        ..onboarded = true
        ..welcomed = true;
    } catch (_) {/* prefs not loaded (tests) — flags above still hold */}
    firstLanding.value = label;
  }
}
