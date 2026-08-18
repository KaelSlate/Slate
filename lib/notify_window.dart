import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

import 'core/theme/app_theme.dart';
import 'ui/widgets/reminder_card.dart';

// The card lives at bottom CENTRE, where the capture pill lives too — one
// place: where you speak, and where you are spoken to. There used to be a
// `NotifyCorner` enum and a `switch` with a `bottomRight` arm here, kept
// against a layout decision that was made a long time ago and never revisited.
// A branch that has exactly one reachable case is not configurability, it is
// a reader's tax.

/// The region padding around the card: enough to hold the shadow, small enough
/// that it does not swallow a wide band of clicks.
///
/// These are the numbers that decide whether the shadow ENDS or is CUT. The
/// window's region is a hard edge — nothing fades across it — so the padding
/// has to reach out to where the shadow is already below perception. At the
/// card's widest blur (46 → sigma 27.1) 52 px is 1.92 sigma: Gaussian coverage
/// outside a straight edge is 0.5·erfc(d/(sigma·sqrt2)) = 0.027, so the
/// strongest layer's 0.56 alpha arrives as 4/255. Under threshold on any
/// background.
///
/// They were 40/34, which at the old blur of 54 left 14/255 ending in a
/// straight line — nothing over a dark desktop, a visible ledge over a bright
/// one. The 12 px this adds per side is dead to clicks; the ledge was dead to
/// nobody.
const double _kPadSide = 52;
const double _kPadTop = 46;
const double _kPadBottom = 48;

/// Entry for the reminder window — a third Flutter engine (`--notify`).
///
/// It is a RENDERER. No database, no prefs, no tray, no hotkey, and it writes no
/// copy: every string arrives formatted from the main isolate, so the house
/// voice lives in one place.
///
/// slate/notify:
///   native -> dart : `warmup`, `show` (cards + lifeMs), `reveal` (-> hit rect),
///                    `revealed` (the window is uncloaked — start the entrance)
///   dart -> native : `ready` (handler installed — safe to ask for anything),
///                    `action` ({action, id, dayMs}), `region` ([l,t,r,b,rad]),
///                    `closed`
const _channel = MethodChannel('slate/notify');

Future<void> runNotifyWindow() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Window.initialize();
  await Window.setEffect(
      effect: WindowEffect.transparent, color: Colors.transparent);
  runApp(const _NotifyApp());
}

class _NotifyApp extends StatelessWidget {
  const _NotifyApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const Scaffold(
        backgroundColor: Colors.transparent,
        body: _NotifyScene(),
      ),
    );
  }
}

/// Every pipeline the real card is about to need, drawn once while the window
/// is cloaked, then thrown away.
///
/// Drawn ON SCREEN, at the corner, and both halves of that are load-bearing.
///
/// Not transparent: `RenderOpacity` skips its child entirely at alpha 0, so an
/// invisible warm-up warms nothing — precisely why the 0.002-alpha seed frame
/// above never did this job. And not parked off-screen either, which was the
/// first attempt: `Stack` clips to its own bounds, and a rasteriser rejects
/// draws outside the clip before it ever reaches the shader. A warm-up nobody
/// can see is a warm-up that compiles nothing.
///
/// It is safe to draw for real because the window is invisible twice over while
/// it exists — DWM-cloaked, and shaped to a 1x1 region until Dart answers
/// `reveal`. [_NotifySceneState._reveal] then waits for a second rasterised
/// frame before answering, so the uncloak cannot catch this still on the
/// surface.
///
/// It covers what a first card actually hits: the three `MaskFilter.blur`
/// passes and the rim's gradients (at rest, and again lifted), the
/// `ImageFilter.blur` inside `MaterialisingContent` at a NON-ZERO t, the
/// `clipRSuperellipse`, the Inter and RobotoMono glyph atlases, the ring's
/// `BoxShadow` and `CheckPainter` stroke, and the collapse tint path.
class _ShaderWarmup extends StatelessWidget {
  const _ShaderWarmup();

  @override
  Widget build(BuildContext context) {
    Widget shell({required ShellShape shape, double content = 0.5}) => SizedBox(
          width: AppTheme.notifyWidth,
          child: ReminderCardShell(
            shape: shape,
            child: MaterialisingContent(
              t: content,
              child: ReminderRow(
                title: 'Warm',
                time: '18:00',
                lede: 'in 5 minutes',
                priority: 2,
                showMark: true,
                isLastRow: true,
                showDivider: false,
                striking: true,
                onOpen: () {},
                onDone: () {},
                onCollapsed: () {},
                onPressedChanged: (_) {},
              ),
            ),
          ),
        );

    return Positioned(
      left: 0,
      top: 0,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // THE ENTRANCE ITSELF, not just its destination.
            //
            // Warming only the settled card left the first card's ENTRANCE
            // paying its own way: measured, it took 150 ms to grow from 132 px
            // to 232 while the third card did it in 76. It started on time and
            // then crawled, which is the "первая не такая же плавная" nobody
            // could point at in a still frame.
            //
            // Every frame of the morph is a different silhouette with a
            // different corner radius, a differently-sized shadow blur and a
            // different ImageFilter sigma inside MaterialisingContent — none of
            // which the settled shape ever draws. Three points across the
            // spring cover the range the real entrance sweeps.
            shell(shape: const ShellShape(widthT: 0.15, heightT: 0.10), content: 0.0),
            shell(shape: const ShellShape(widthT: 0.55, heightT: 0.45), content: 0.25),
            shell(shape: const ShellShape(widthT: 0.85, heightT: 0.80), content: 0.75),
            shell(shape: ShellShape.settled, content: 1.0),
            // ...and the lifted, hovered state, whose rim gradients and wider
            // shadow are another set of pipelines again.
            shell(shape: ShellShape.settled),
            shell(
              shape: const ShellShape(
                collapseT: 0.5,
                collapseCenter: Offset(312, 28),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

@immutable
class _Card {
  const _Card({
    required this.id,
    required this.title,
    required this.time,
    required this.lede,
    required this.dayMs,
    required this.priority,
  });

  factory _Card.fromMap(Map<dynamic, dynamic> m) => _Card(
        id: (m['id'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        time: (m['time'] as String?) ?? '',
        lede: (m['lede'] as String?) ?? '',
        dayMs: (m['dayMs'] as int?) ?? 0,
        priority: (m['priority'] as int?) ?? 0,
      );

  final String id;
  final String title;
  final String time;

  /// Arrives written. This window does not compose copy — see the note on
  /// `ReminderCard.lede`, which is where the sentence is actually decided.
  final String lede;

  final int dayMs;
  final int priority;
}

class _NotifyScene extends StatefulWidget {
  const _NotifyScene();

  @override
  State<_NotifyScene> createState() => _NotifySceneState();
}

class _NotifySceneState extends State<_NotifyScene>
    with TickerProviderStateMixin {
  /// THE MORPH. Two springs, one per axis, and they are deliberately out of
  /// step: the width has the bigger journey and leads, the height fills out
  /// behind it. One spring would just be a box getting bigger; two make it a
  /// shape becoming another shape.
  ///
  /// Neither of them scales anything. They drive a real width and a real
  /// height, the contents sit at their final size the whole time, and so not a
  /// single glyph is ever stretched — which is exactly why Apple can afford to
  /// deform a Dynamic Island as hard as it does.
  late final AnimationController _mw;
  late final AnimationController _mh;

  /// The shadow, on a critically damped spring at the width's response: it
  /// trails the body by two or three frames and lands with it. That lag is mass.
  late final AnimationController _shadow;

  /// Unanswered: it recedes.
  late final AnimationController _exit;

  /// Answered: the card collapses INTO the ring that was pressed.
  late final AnimationController _collapse;

  late final AnimationController _warm;

  final GlobalKey _cardKey = GlobalKey();

  /// The box the shell's painters live in — the space the collapse target has
  /// to be expressed in.
  final GlobalKey _paintKey = GlobalKey();
  final Map<String, GlobalKey> _ringKeys = {};
  List<_Card> _cards = const [];
  final Set<String> _striking = {};
  int _lifeMs = 7000;
  Timer? _life;
  Timer? _shadowLag;

  /// If `revealed` never arrives — a native side that answered `reveal` and
  /// then died, or a message lost between engines — the card would sit frozen
  /// as a seed pill forever, which is a card that does not exist. Start the
  /// entrance anyway. Late is a flaw; absent is a bug.
  Timer? _entranceFallback;
  bool _leaving = false;
  bool _hovering = false;
  bool _pressed = false;
  List<int>? _lastRegion;
  Offset? _collapseCenter;


  /// Live horizontal offset while the card is being carried. Unbounded and on
  /// the ticker like every other motion here: the hand-rolled Stopwatch loops
  /// this replaced drove the offset through `setState`, which rebuilt the whole
  /// row column — every row, every ring — at pointer rate, on the one gesture
  /// that has to feel glued to the finger.
  late final AnimationController _drag;
  bool _dragging = false;

  /// Once per PROCESS, not per card.
  static bool _warmedOnce = false;

  /// True only across the two cloaked frames of the first [_reveal].
  bool _warmingShaders = false;

  @override
  void initState() {
    super.initState();
    // Headroom for the overshoot: at bounce 0.30 the width passes its target by
    // about 4 %, and a controller that clamps at 1.0 would eat exactly the part
    // of the motion that is worth having.
    _mw = AnimationController(vsync: this, lowerBound: 0.0, upperBound: 1.3);
    _mh = AnimationController(vsync: this, lowerBound: 0.0, upperBound: 1.3);
    _shadow = AnimationController(vsync: this, lowerBound: 0.0, upperBound: 1.3);
    _exit = AnimationController(
        vsync: this, duration: AppTheme.notifyDismissDuration);
    _collapse = AnimationController(
        vsync: this, duration: AppTheme.notifyCollapseToRing);
    _warm = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _drag = AnimationController.unbounded(vsync: this);
    // The window's shape follows the card wherever it goes, on every frame of
    // every path that moves it — drag, flick, settle — without each of those
    // having to remember to say so. AFTER the frame, never from this listener
    // directly: see [_pushRegionAfterFrame].
    _drag.addListener(_pushRegionAfterFrame);
    _channel.setMethodCallHandler(_onNative);
    // The runner may not speak to this engine before this line runs, so it is
    // told rather than left to guess. It answers by asking for the shader
    // warm-up — the thing that has to happen minutes before the first reminder
    // rather than in front of it.
    _channel.invokeMethod<void>('ready').ignore();
  }

  @override
  void dispose() {
    _life?.cancel();
    _shadowLag?.cancel();
    _entranceFallback?.cancel();
    _hoverBridge?.cancel();
    _mw.dispose();
    _mh.dispose();
    _shadow.dispose();
    _exit.dispose();
    _collapse.dispose();
    _warm.dispose();
    _drag.dispose();
    super.dispose();
  }

  Future<dynamic> _onNative(MethodCall call) async {
    switch (call.method) {
      case 'warmup':
        await _warmup();
        return null;
      case 'show':
        _show(call.arguments);
        return null;
      case 'reveal':
        return await _reveal();
      case 'revealed':
        _beginEntrance();
        return null;
    }
    return null;
  }

  /// The window is UNCLOAKED and on screen. Only now may the entrance play.
  ///
  /// Splitting this out of `reveal` is the whole fix for "I only see the last
  /// 20 % of the animation". `reveal` used to start the spring on its first
  /// line and then wait — for two frames once, and after the rasterisation gate
  /// landed, for considerably more than two — with the window cloaked the
  /// entire time. The card was busy arriving at something nobody could see yet,
  /// and what finally appeared was whatever was left of it. On the very first
  /// card of a session, where shader compilation is also on that path, there
  /// was nothing left at all: it simply cut in, which is exactly what got
  /// reported.
  ///
  /// Under the cloak the card now sits STILL, at seed. The spring starts here.
  void _beginEntrance() {
    _entranceFallback?.cancel();
    if (!mounted || _leaving || _cards.isEmpty) return;
    if (_mw.value > 0.0) return; // already running or already home
    if (MediaQuery.of(context).disableAnimations) {
      _mw.value = 1.0;
      _mh.value = 1.0;
      _shadow.value = 1.0;
    } else {
      _startMorph();
    }
    _armLife();
  }

  /// Frames on an invisible window, for two different callers.
  ///
  /// The runner asks for this ONCE AT STARTUP, and again whenever the display
  /// changed geometry while the window sat hidden (an engine only adopts a
  /// resize while it is PRESENTING). Both want the same thing: real frames, no
  /// pixels reaching anybody.
  ///
  /// The startup call is what takes shader compilation off the path of the
  /// first reminder someone ever gets. Skia compiles SkSL on first draw, and
  /// the first card was paying for three MaskFilter.blur passes, two gradients
  /// and an ImageFilter at the exact moment its whole value is landing at once.
  /// Done here, minutes earlier on a window nobody is looking at, the first
  /// card behaves like the tenth.
  ///
  /// SELF-VERIFYING, because "does a cloaked window rasterise" is an empirical
  /// question and not one to bet a feature on. `_awaitRaster` reports whether it
  /// actually saw the GPU finish frames; only then is the warm-up recorded as
  /// done. If the compositor declined, `_warmedOnce` stays false and the first
  /// show warms under its own cloak exactly as before — slower, still correct.
  Future<void> _warmup() async {
    _resetMotion();
    _warm.forward(from: 0.0);
    if (_warmedOnce) return;
    setState(() => _warmingShaders = true);
    final rastered = await _awaitRaster();
    if (!mounted) return;
    setState(() => _warmingShaders = false);
    // Take it back off the surface before anyone can be shown this window.
    await _awaitRaster();
    _warmedOnce = rastered;
  }

  void _resetMotion() {
    _leaving = false;
    _shadowLag?.cancel();
    _exit.value = 0.0;
    _collapse.value = 0.0;
    _collapseCenter = null;
    _mw.value = 0.0;
    _mh.value = 0.0;
    _shadow.value = 0.0;
    _drag.stop();
    _drag.value = 0.0;
  }

  void _show(dynamic args) {
    if (args is! Map) return;
    final raw = (args['cards'] as List?) ?? const [];
    // Ids must be present and unique. Two rows sharing one carry the same
    // `GlobalKey` onto two live rings in a single frame, which is not a glitch
    // but a hard framework assertion — and the scheduler builds a merged batch
    // from two lists without deduping either.
    final seen = <String>{};
    final cards = raw
        .whereType<Map>()
        .map((m) => _Card.fromMap(m))
        .where((c) =>
            c.title.isNotEmpty && c.id.isNotEmpty && seen.add(c.id))
        .toList();
    if (cards.isEmpty) return;

    // A card that arrives WHILE the last one is leaving.
    //
    // The runner does not re-run `reveal` for an already-visible window, and
    // `reveal` is the only thing that clears `_leaving` — so this batch used to
    // be set, then wiped by the `_close()` already in flight, while the native
    // side had returned true and the scheduler had sealed every moment in it.
    // The reminder was gone for good, which is the one failure this whole
    // feature is built to prevent. The window is only ~190 ms wide on a timeout
    // and ~600 ms on the answered exit — and the answered exit is exactly when
    // the next card is most likely to land, because the person is right there.
    final interrupting = _leaving;
    if (interrupting) {
      _exit.stop();
      _collapse.stop();
      _resetMotion();
    }

    final growing = _cards.isNotEmpty && !interrupting;
    setState(() {
      _cards = cards;
      _lifeMs = (args['lifeMs'] as int?) ?? 7000;
      _striking.removeWhere((id) => !cards.any((c) => c.id == id));
      _ringKeys.removeWhere((id, _) => !cards.any((c) => c.id == id));
    });
    if (interrupting) {
      // It was on its way out; bring it back the way it came in.
      if (mounted && !MediaQuery.of(context).disableAnimations) {
        _startMorph();
      } else {
        _mw.value = _mh.value = _shadow.value = 1.0;
      }
    }
    if (growing || interrupting) _armLife();
    _pushRegionAfterFrame();
  }

  /// Answered once a frame has actually been RASTERISED — the reply is what
  /// uncloaks the window, so it must not come back before real pixels exist.
  ///
  /// It deliberately does NOT start the entrance. Everything below happens with
  /// the window invisible, and a spring that runs while nobody can see it is a
  /// spring nobody sees. The card holds still at seed until the runner reports
  /// back through `revealed` — see [_beginEntrance].
  Future<List<int>?> _reveal() async {
    _resetMotion();
    _entranceFallback?.cancel();

    // SHADER WARM-UP, paid for under the cloak.
    //
    // We are on Skia, not Impeller (FLUTTER_IMPELLER in the runner's CMake is
    // read by nobody), so the first draw of each pipeline this card needs is a
    // runtime SkSL compile — on the one window whose entire value is landing
    // instantly. That compile is what used to overrun the uncloak fallback and
    // flash a grey slab.
    //
    // The window is CLOAKED across all of this: the cloak goes on in ShowCards
    // and comes off in the reply to this method, and the region is 1x1 until
    // that reply lands. So the warm-up is invisible twice over, which is why it
    // can afford to be drawn ON SCREEN — see [_ShaderWarmup].
    if (!_warmedOnce) {
      _warmedOnce = true;
      setState(() => _warmingShaders = true);
      await _awaitFrames();
      if (!mounted) return null;
      setState(() => _warmingShaders = false);
    }

    // ...and once more, so what the uncloak reveals is the real card alone.
    // On the first show this also takes the warm-up back off the surface; on
    // every later one it is the single wait that matters.
    await _awaitFrames();
    if (!mounted) return null;
    final r = _hitRect(_drag.value);
    _lastRegion = r;
    _regionDrag = _drag.value;

    // START THE ENTRANCE HERE, on the same breath as the answer.
    //
    // Returning this rect is what makes the runner apply the region and
    // uncloak, so this line and the window appearing are the same instant give
    // or take a frame. Every looser arrangement was measured and cost real
    // time: waiting for the runner's `revealed` call back into Dart left the
    // card sitting on screen as a motionless seed pill for about 135 ms before
    // it sprang open, and a 60 ms timer only shortened that. A still pill
    // followed by a spring reads worse than either half of it.
    //
    // The trade is that the first frame or two of the spring may play while the
    // window is still cloaked — a few per cent of 280 ms, against a third of a
    // second of visible stillness. `revealed` stays wired as a belt for the
    // path where this object somehow never gets asked; [_beginEntrance] is
    // idempotent, so both firing changes nothing.
    _beginEntrance();
    return r;
  }

  /// Completes when a frame built from here on has actually been RASTERISED —
  /// not merely built.
  ///
  /// `SchedulerBinding.endOfFrame` resolves when the UI THREAD is finished with
  /// a frame: built, laid out, painted, layer tree handed over. The raster
  /// thread has not touched it yet. On the first card of a session that thread
  /// is compiling SkSL for three MaskFilter.blur passes, two gradients and an
  /// ImageFilter, and it runs far behind — so counting endOfFrames and then
  /// uncloaking revealed a window whose swapchain had never presented. That is
  /// the cold-swapchain law from the pill saga, in a new window: what reaches
  /// the screen is whatever the compositor had, which is nothing, and the card
  /// then appears to catch up with itself. The grey flash and the "it arrives
  /// laggy" are the same defect seen from two angles.
  ///
  /// TWO qualifying passes, not one. A raster pass can finish after the mark
  /// and still belong to a frame built BEFORE it, if the raster thread was
  /// behind — which, mid shader compile, is exactly the state it is in. The
  /// second is provably no older than ours.
  /// Frames, cheaply — the gate on the path a person is actually waiting on.
  ///
  /// NOT [_awaitRaster]. `addTimingsCallback` is a PROFILING api: the engine
  /// batches FrameTiming records and flushes them periodically rather than at
  /// the end of each frame, so waiting on two of them cost this path its whole
  /// 400 ms timeout. Measured: uncloak at 462 ms after the ask, against 62 ms
  /// for the frame itself. That delay is what read as "it appears late and the
  /// sound arrives before the picture" — the chime goes out when ShowCards
  /// returns, and the picture was waiting on a profiler.
  ///
  /// Nothing is lost by being cheap here. Uncloaking a frame early can only
  /// expose an unpainted window, and an unpainted window has nothing to show:
  /// the region is 1x1 until this answer lands, and WM_ERASEBKGND is claimed so
  /// the class brush never fills anything. The rasterisation guarantee stopped
  /// being what stands between a grey slab and the screen the moment those two
  /// existed.
  Future<void> _awaitFrames() async {
    // ONE. It buys the only thing still worth buying here: the card has been
    // laid out, so `_hitRect` describes a real box rather than a guess. It used
    // to be two, and before that two plus a rasterisation gate, and every extra
    // wait was a millisecond the person spent looking at nothing while the
    // chime had already played.
    await SchedulerBinding.instance.endOfFrame;
  }

  /// Returns TRUE only if real rasterisation was observed, FALSE if it gave up
  /// waiting. Callers use that to tell "the GPU did the work" from "we stopped
  /// asking" — which is the difference between a warm-up that warmed something
  /// and one that merely took time.
  ///
  /// Only for the STARTUP warm-up, where nobody is waiting and a batched
  /// profiling api is affordable. Never on the path to showing a card.
  Future<bool> _awaitRaster() async {
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return false;

    final markUs = DateTime.now().microsecondsSinceEpoch;
    final done = Completer<void>();
    var seen = 0;

    void onTimings(List<ui.FrameTiming> timings) {
      for (final t in timings) {
        final finished =
            t.timestampInMicroseconds(ui.FramePhase.rasterFinishWallTime);
        if (finished < markUs) continue;
        if (++seen >= 2) {
          if (!done.isCompleted) done.complete();
          return;
        }
      }
      // Nothing here is guaranteed to be animating — under Reduce Motion the
      // morph is skipped entirely — and a frame that is never scheduled is a
      // frame that never rasterises.
      if (!done.isCompleted) SchedulerBinding.instance.scheduleFrame();
    }

    SchedulerBinding.instance.addTimingsCallback(onTimings);
    SchedulerBinding.instance.scheduleFrame();
    // Never hang. The native side has its own 700 ms net for a dead engine;
    // this one is for an engine that is merely not reporting.
    await Future.any([
      done.future,
      Future<void>.delayed(const Duration(milliseconds: 400)),
    ]);
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
    return done.isCompleted;
  }

  /// Both axes on the SAME response, so the card has a moment of arrival — and
  /// the shadow on the SAME CURVE, started two frames late.
  ///
  /// A differently-damped spring is not a lag, it is a divergent curve: the old
  /// shadow sat 6 px inside the body mid-entrance and 11 px outside it at rest,
  /// so it spent a quarter of a second changing its relationship to the thing
  /// casting it. A delayed start of the identical curve is what an object's own
  /// shadow actually does.
  void _startMorph() {
    _shadowLag?.cancel();
    _mw.animateWith(_spring(AppTheme.notifyMorphWidthDamping));
    _mh.animateWith(_spring(AppTheme.notifyMorphHeightDamping));
    _shadowLag = Timer(AppTheme.notifyShadowLag, () {
      if (mounted && !_leaving) {
        _shadow.animateWith(_spring(AppTheme.notifyMorphWidthDamping));
      }
    });
  }

  SpringSimulation _spring(double damping) => SpringSimulation(
        SpringDescription(
          mass: 1.0,
          stiffness: AppTheme.notifyMorphStiffness,
          damping: damping,
        ),
        0.0,
        1.0,
        0.0,
      );

  /// [left, top, right, bottom, radius] in PHYSICAL pixels, padded for the
  /// shadow. Measured on the RESTING layout: `_cardKey` sits ABOVE every
  /// animated transform and the contents are laid out at full size from the
  /// first frame, so this box is correct before the morph has started.
  ///
  /// Note what this does NOT claim. The card is not *pressable* over that whole
  /// box while it grows — the morph clip rejects hit tests outside the current
  /// silhouette, deliberately, because a control you cannot see is a control
  /// you must not be able to trigger. The region is the window's shape; the
  /// silhouette is the target.
  List<int>? _hitRect(double dx) {
    final ctx = _cardKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final media = MediaQuery.of(context);
    final dpr = media.devicePixelRatio;
    final o = box.localToGlobal(Offset.zero);
    // Being carried away, the region TRAVELS WITH THE CARD. It must not simply
    // open to the screen edge.
    //
    // On Windows 11 the window carries a DWM system backdrop over its whole
    // extended frame, so every pixel the region exposes shows acrylic — not the
    // desktop. A full-width band therefore paints a grey stripe across the
    // screen on either side of the card for as long as a drag is live.
    //
    // `_cardKey` sits above the travelling transform, so `o.dx` is the RESTING
    // x and the carried offset has to be added back here by hand. It is passed
    // in rather than read from `_drag` because it is deliberately NOT the
    // current offset — see [_pushRegionNow].
    return [
      ((o.dx + dx - _kPadSide) * dpr).floor(),
      ((o.dy - _kPadTop) * dpr).floor(),
      ((o.dx + dx + box.size.width + _kPadSide) * dpr).ceil(),
      ((o.dy + box.size.height + _kPadBottom) * dpr).ceil(),
      (AppTheme.notifyRadius * dpr).round(),
    ];
  }

  /// The card grew a row, lost one, or moved. Either way the window's shape has
  /// to follow, or the bottom of the card stops taking clicks and a carried
  /// card is sheared along a hard line.
  ///
  /// ALWAYS after the frame. Pushed from an animation listener instead, this
  /// ran in the animation phase — before build, layout and paint — while
  /// `SetWindowRgn` takes effect at the compositor's next pass. The shape
  /// arrived ahead of the pixels it was the shape of.
  void _pushRegionAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _pushRegionNow());
  }

  /// The region must never describe a position the card has not been PAINTED at
  /// yet.
  ///
  /// Even from a post-frame callback the newest offset is still one present
  /// ahead of the screen: the UI thread has finished with this frame, the
  /// raster thread has not. Shape the window for that newest offset and its
  /// leading rounded corner opens a sliver of window beyond where the shadow
  /// has been drawn — a bright arc that appears and vanishes every frame of a
  /// slow drag, which is exactly what a flickering `[` is.
  ///
  /// So the region is shaped for the offset of the frame BEFORE, which is the
  /// one actually on screen. The lag is capped below [_kPadSide] so that at
  /// flick speeds — where a frame can carry the card further than its own
  /// padding — the trailing region can still never bite into the card itself.
  /// What it clips instead is the far tail of the shadow, about 4/255.
  static const double _kRegionLagMax = 32.0;
  double _regionDrag = 0.0;

  void _pushRegionNow() {
    if (!mounted || _leaving) return;
    final now = _drag.value;
    final travelled = now - _regionDrag;
    final lag = travelled.abs() > _kRegionLagMax
        ? _kRegionLagMax * (travelled.isNegative ? -1.0 : 1.0)
        : travelled;
    _regionDrag = now;
    final r = _hitRect(now - lag);
    if (r == null) return;
    // Deduped on the integer rect, so a drag only reaches the OS on the frames
    // where the region actually differs.
    if (_lastRegion != null && _listEq(_lastRegion!, r)) return;
    _lastRegion = r;
    // .ignore() for the same reason as Sfx (lib/core/sfx/sfx.dart): this
    // engine returns before runZonedGuarded, so a rejectable future left
    // behind here surfaces as an unhandled async error with nobody to catch
    // it. Fire and forget — a shape that fails to update is not fatal.
    _channel.invokeMethod<void>('region', r).ignore();
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Reduce Motion. Same name and meaning as the shell's own getter.
  bool get _stillMotion =>
      mounted && MediaQuery.of(context).disableAnimations;

  void _armLife() {
    _life?.cancel();
    // lifeMs 0 = `!!`: it waits to be noticed. It still never repeats and never
    // rings again — waiting is not nagging.
    if (_lifeMs <= 0 || _hovering) return;
    _life = Timer(Duration(milliseconds: _lifeMs), _leave);
  }

  /// TWO sources, one answer.
  ///
  /// The card's own MouseRegion is exactly card-sized, and the dismiss button
  /// deliberately overhangs the top-left corner. Moving from the card onto that
  /// overhang is an exit from one and an enter into the other, and read
  /// separately it meant the button disappeared from under the pointer that was
  /// reaching for it while the dismissal clock quietly restarted.
  ///
  /// Flutter dispatches every exit and then every enter inside a single mouse
  /// tracker update, and `setState` only marks the tree dirty, so the moment
  /// where both are false never reaches a frame. The timer work below is
  /// synchronous for the same reason: the cancel lands before anything ticks.
  bool _hoverCard = false;
  bool _hoverDismiss = false;

  void _onHover(bool over) {
    if (_hoverCard == over) return;
    _hoverCard = over;
    _settleHover();
  }

  void _onDismissHover(bool over) {
    if (_hoverDismiss == over) return;
    _hoverDismiss = over;
    _settleHover();
  }

  /// A BRIDGE, not a boolean.
  ///
  /// Leaving the card and arriving on the button are two separate events, and
  /// they do not always land in the same mouse-tracker update. When they do
  /// not, `_hovering` is false for one frame — long enough for the button to
  /// unmount, and once it is gone there is nothing left to receive the enter
  /// that was about to arrive. The button vanished from under the pointer
  /// reaching for it and never came back; photographed on the live card.
  ///
  /// So arriving is instant and leaving waits a beat. If anything claims the
  /// pointer in that beat, nothing happened at all.
  Timer? _hoverBridge;

  void _settleHover() {
    final over = _hoverCard || _hoverDismiss;
    _hoverBridge?.cancel();
    if (!over && _hovering) {
      _hoverBridge = Timer(Duration.zero, () {
        if (!mounted) return;
        if (_hoverCard || _hoverDismiss) return; // something caught it
        _applyHover(false);
      });
      return;
    }
    _applyHover(over);
  }

  void _applyHover(bool over) {
    if (_hovering == over) return;
    // setState, because the dismiss button is offered on exactly this bit and
    // it lives inside a builder that would otherwise only run when an
    // animation ticks.
    setState(() => _hovering = over);
    if (over) {
      _life?.cancel();
    } else if (_lifeMs > 0) {
      _life?.cancel();
      _life = Timer(AppTheme.notifyHoverGrace, _leave);
    }
  }

  /// Unanswered: it recedes and dissolves. Deliberately about half the
  /// entrance, and with no spring at all — what leaves must not ask for
  /// attention on the way out.
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _life?.cancel();
    _shadowLag?.cancel();
    _mw.stop();
    _mh.stop();
    _shadow.stop();
    // `.orCancel`, because a cancelled TickerFuture never completes: a plain
    // await here would hang the close path forever the moment anything stops
    // the controller — which is now reachable, since an incoming card revives
    // this animation mid-flight.
    final done = await _exit
        .animateTo(1.0, curve: Curves.easeInCubic)
        .orCancel
        .then((_) => true)
        .catchError((Object _) => false);
    if (!done || !mounted || !_leaving) return;
    await _close();
  }

  /// Answered: the shell shrinks INTO the ring that was pressed, greening as it
  /// goes, and winks out. The action finishes where the person performed it —
  /// which is macOS's own "shrink to a circle and fade", aimed at the circle
  /// that was actually clicked.
  Future<void> _collapseIntoRing(String id) async {
    // Hands over WHILE the tick is still being drawn, not after it. See
    // AppTheme.notifyDoneHandoff — the pause this replaced was dead air.
    await Future<void>.delayed(AppTheme.notifyDoneHandoff);
    if (!mounted || _leaving) return;
    if (MediaQuery.of(context).disableAnimations) {
      await _leave();
      return;
    }
    final centre = _ringCentre(id);
    if (centre == null) {
      await _leave();
      return;
    }
    _leaving = true;
    _life?.cancel();
    _shadowLag?.cancel();
    _mw.stop();
    _mh.stop();
    _shadow.stop();
    setState(() => _collapseCenter = centre);
    final done = await _collapse
        .forward(from: 0.0)
        .orCancel
        .then((_) => true)
        .catchError((Object _) => false);
    if (!done || !mounted || !_leaving) return;
    await _close();
  }

  /// The ring's centre in the SHELL PAINTER's coordinate space.
  ///
  /// Measured against `_cardKey` instead, the answer came out four pixels high
  /// — every transform between the two boxes is composed into the result, and
  /// the hover lift is sitting right there at a full −4 px, because the person
  /// whose click started this necessarily had the pointer on the card. The
  /// collapse would then land next to the ring rather than on it, on a target
  /// eighteen pixels across.
  Offset? _ringCentre(String id) {
    final ring = _ringKeys[id]?.currentContext?.findRenderObject();
    final card = _paintKey.currentContext?.findRenderObject();
    if (ring is! RenderBox || card is! RenderBox) return null;
    if (!ring.hasSize || !card.hasSize) return null;
    return ring.localToGlobal(ring.size.center(Offset.zero), ancestor: card);
  }

  Future<void> _close() async {
    if (!mounted) return;
    _entranceFallback?.cancel();
    setState(() {
      _cards = const [];
      _striking.clear();
      _ringKeys.clear();
      _drag.value = 0.0;
      _pressed = false;
    });
    _lastRegion = null;
    _regionDrag = 0.0;
    // The card is gone, so no exit event is ever coming for whatever the
    // pointer was last over. Left set, the NEXT card would believe it was born
    // hovered — it would never arm its own dismissal clock, and it would wear
    // the close button from its first frame.
    _hoverCard = false;
    _hoverDismiss = false;
    _hovering = false;
    await _channel.invokeMethod('closed');
  }

  void _act(String action, _Card card) {
    _channel.invokeMethod('action', <String, dynamic>{
      'action': action,
      'id': card.id,
      'dayMs': card.dayMs,
    });
  }

  /// One row of several has finished folding. Drop it; the rest close up.
  void _rowGone(_Card card) {
    if (!mounted) return;
    final rest = _cards.where((c) => c.id != card.id).toList();
    setState(() {
      _cards = rest;
      _striking.remove(card.id);
      _ringKeys.remove(card.id);
    });
    if (rest.isEmpty) {
      _leave();
    } else {
      _pushRegionAfterFrame();
    }
  }

  @override
  Widget build(BuildContext context) {
    // No full-screen gesture layer and no scrim: outside the card this window
    // does not exist for the pointer (SetWindowRgn on the runner side).
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _warm,
            builder: (context, _) => IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.002 * _warm.value),
              ),
            ),
          ),
        ),
        if (_cards.isNotEmpty) _positioned(),
        if (_warmingShaders) const _ShaderWarmup(),
      ],
    );
  }

  Widget _positioned() {
    // `_cardKey` sits above every animated transform on purpose — the hit
    // region is measured from the resting layout, not from a frame mid-morph.
    final card = SizedBox(
      key: _cardKey,
      // The shell is WIDER than the card by `notifyDismissReach` on each side —
      // that reserve is what lets the dismiss button, which straddles the top
      // -left corner, take a click at all. Hand it the room or the card itself
      // gets squeezed by 28 px.
      width: AppTheme.notifyWidth + AppTheme.notifyDismissReach * 2,
      child: _travelling(),
    );
    return Positioned(
      left: 0,
      right: 0,
      bottom: 48,
      child: Center(child: card),
    );
  }

  Widget _travelling() {
    return GestureDetector(
      // Flick it away, the way every notification on a Mac can be flicked away.
      // Either direction: the card sits bottom-CENTRE, so it has no edge it
      // came from, and refusing one side was left over from a corner layout
      // that no longer exists.
      onHorizontalDragStart: (_) {
        _dragging = true;
        _drag.stop();
        _life?.cancel();
      },
      // No setState: the controller is in the AnimatedBuilder's merge, so a
      // drag frame repaints the shell and leaves `child` — the whole row
      // column — untouched.
      onHorizontalDragUpdate: (d) => _drag.value += d.delta.dx,
      onHorizontalDragEnd: (d) {
        _dragging = false;
        final v = d.velocity.pixelsPerSecond.dx;
        // Either a decisive flick or past a third of the way out.
        if (v.abs() > 320 || _drag.value.abs() > AppTheme.notifyWidth * 0.33) {
          _flickOut(v);
        } else {
          _settleBack();
        }
      },
      child: AnimatedBuilder(
        animation:
            Listenable.merge([_mw, _mh, _shadow, _exit, _collapse, _drag]),
        builder: (context, child) {
          final ex = _exit.value;
          final col = _collapse.value;

          // The unanswered exit is GEOMETRY too. It used to be a
          // `Transform.scale` over a frozen silhouette — a shrinking PICTURE of
          // a card, which is the exact imitation-of-a-morph this whole file was
          // written to stop doing. It arrived as a shape; it leaves as one.
          final shrink = 0.055 * ex;

          final shape = ShellShape(
            widthT: _mw.value - shrink,
            heightT: _mh.value - shrink,
            collapseT: col,
            collapseCenter: _collapseCenter,
          );
          final shadowShape = ShellShape(
            widthT: _shadow.value - shrink,
            heightT: _shadow.value - shrink,
            collapseT: col,
            collapseCenter: _collapseCenter,
          );

          // Zero on entry now — the morph grows from a pinned bottom edge, so
          // the top edge is already rising on the height spring and a second
          // upward motion on a second clock only fought it. The exit still
          // settles downward, which is a different verb.
          final rise = AppTheme.notifyEnterRise *
                  (1 - _mw.value.clamp(0.0, 1.0)) +
              10.0 * ex;

          // Fades out as it is carried away, so a flick feels like release
          // rather than an object stuck to the cursor. Distance, not direction.
          final dragFade =
              (1.0 - (_drag.value.abs() / (AppTheme.notifyWidth * 0.9)))
                  .clamp(0.0, 1.0);

          // The collapse ends by winking out, not by being cut — and only once
          // the shape is ALREADY a circle. Started earlier, the circle existed
          // for about one frame at a fifth of its opacity, and everything a
          // person actually saw was an anonymous capsule travelling.
          final collapseFade = 1.0 -
              ((col - AppTheme.notifyCollapseShapeEnd) /
                      (1.0 - AppTheme.notifyCollapseShapeEnd))
                  .clamp(0.0, 1.0);

          // The contents MATERIALISE: opacity and blur move together, over the
          // tail of the height spring, so they settle INTO a shell that is
          // still arriving. They are never scaled and never distorted. On the
          // answered exit the shrinking clip removes them instead — see
          // `ShellShape.contentOpacity`.
          final contentFade = shape.contentOpacity;

          return Transform.translate(
            offset: Offset(_drag.value, rise),
            child: Opacity(
              opacity: ((1.0 - ex * 0.9) * dragFade * collapseFade)
                  .clamp(0.0, 1.0),
              child: ReminderCardShell(
                shape: shape,
                shadowShape: shadowShape,
                pressed: _pressed,
                paintKey: _paintKey,
                onHoverChanged: _onHover,
                // Offered only once the card has actually ARRIVED, and only
                // while it is not on its way out. `isMorphing` is the honest
                // test: with the pointer already resting where the card lands,
                // hover is true from the first frame, and without this the
                // button rode up on a shell that was still springing open —
                // a control aimed at a moving target. One offered during the
                // exit is a promise the card cannot keep.
                overlay: DismissButton(
                  visible: _hovering &&
                      !_leaving &&
                      !shape.isMorphing &&
                      col <= 0 &&
                      ex <= 0,
                  onTap: _leave,
                  onHoverChanged: _onDismissHover,
                ),
                child: MaterialisingContent(
                  t: contentFade,
                  child: child!,
                ),
              ),
            ),
          );
        },
        child: _rowColumn(),
      ),
    );
  }

  Widget _rowColumn() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _cards.length; i++)
          ReminderRow(
            key: ValueKey(_cards[i].id),
            ringKey: _ringKeys.putIfAbsent(_cards[i].id, () => GlobalKey()),
            title: _cards[i].title,
            time: _cards[i].time,
            lede: _cards[i].lede,
            priority: _cards[i].priority,
            showMark: i == 0,
            isLastRow: _cards.length == 1,
            showDivider: i > 0,
            striking: _striking.contains(_cards[i].id),
            onOpen: () {
              _act('open', _cards[i]);
              _leave();
            },
            onDone: () {
              final c = _cards[i];
              if (_striking.contains(c.id)) return;
              final last = _cards.length == 1;
              // Or the life timer wins the race during the tick, and the person
              // gets the generic recede instead of the collapse they earned.
              _life?.cancel();
              setState(() => _striking.add(c.id));
              _act('done', c);
              if (last) _collapseIntoRing(c.id);
            },
            onCollapsed: () => _rowGone(_cards[i]),
            onPressedChanged: (down) {
              if (_pressed == down) return;
              setState(() => _pressed = down);
            },
          ),
      ],
    );
  }

  /// Carried past the point of no return: let it go with the speed it was
  /// given, then close for real.
  ///
  /// Reduce Motion does NOT cancel this. WCAG 2.3.3 exempts motion essential to
  /// functionality, and Apple keeps direct manipulation under the setting for
  /// the same reason — a card that refuses to follow the hand that threw it
  /// reads as broken, to exactly the people the setting protects. What goes is
  /// the free flight, not the gesture.
  Future<void> _flickOut(double velocity) async {
    if (_leaving) return;
    _leaving = true;
    _life?.cancel();
    // Direction from the throw when there was one, otherwise from where the
    // card already is.
    final sign = velocity.abs() > 320
        ? (velocity.isNegative ? -1.0 : 1.0)
        : (_drag.value.isNegative ? -1.0 : 1.0);
    final target =
        sign * (AppTheme.notifyWidth + AppTheme.notifySlideOvershoot);

    if (_stillMotion) {
      _drag.value = target;
      await _close();
      return;
    }

    // Raced against a hard deadline. This window is always-on-top and has no
    // taskbar button, so a flight that never finishes is not a dropped frame —
    // it is a card stranded over everything the person is trying to work in,
    // with no way to dismiss it. The simulation terminates on its own; the race
    // is there for the case where the engine stops producing frames at all.
    final flight = _drag
        .animateWith(FrictionSimulation.through(
          _drag.value,
          target,
          sign * math.max(velocity.abs(), 900),
          0,
        ))
        .orCancel
        .then((_) => true)
        .catchError((Object _) => false);
    final done = await Future.any([
      flight,
      Future<bool>.delayed(const Duration(milliseconds: 600), () => true),
    ]);
    if (!done || !mounted) return;
    await _close();
  }

  /// Not far enough: spring back home, then hand the shape back to the window.
  void _settleBack() {
    void home() {
      if (!mounted || _dragging) return;
      _armLife();
      // MUST happen. The region was opened across the whole screen at drag
      // start; leaving it there is a full-width invisible window swallowing
      // every click in that band until the card times out.
      _pushRegionAfterFrame();
    }

    if (_stillMotion) {
      _drag.value = 0.0;
      home();
      return;
    }

    _drag
        .animateWith(SpringSimulation(
          SpringDescription(
            mass: 1.0,
            stiffness: AppTheme.notifyMorphStiffness,
            damping: AppTheme.notifyMorphWidthDamping,
          ),
          _drag.value,
          0.0,
          0.0,
        ))
        .orCancel
        .then((_) => home())
        .catchError((Object _) {});
  }
}
