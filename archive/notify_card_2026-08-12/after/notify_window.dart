import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

import 'core/theme/app_theme.dart';
import 'ui/widgets/reminder_card.dart';

/// Where the card lives. Bottom centre is where the capture pill lives too —
/// one place: where you speak, and where you are spoken to.
enum NotifyCorner { bottomRight, bottomCenter }

const NotifyCorner kNotifyCorner = NotifyCorner.bottomCenter;

const double _kEdgeInset = 24;

/// The region padding around the card: enough to hold the shadow, small enough
/// that it does not swallow a wide band of clicks. Past this the shadow is
/// already below perception.
const double _kPadSide = 40;
const double _kPadTop = 34;
const double _kPadBottom = 48;

/// Entry for the reminder window — a third Flutter engine (`--notify`).
///
/// It is a RENDERER. No database, no prefs, no tray, no hotkey, and it writes no
/// copy: every string arrives formatted from the main isolate, so the house
/// voice lives in one place.
///
/// slate/notify:
///   native -> dart : `warmup`, `show` (cards + lifeMs), `reveal` (-> hit rect)
///   dart -> native : `action` ({action, id, dayMs}), `region` ([l,t,r,b,rad]),
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
  bool _leaving = false;
  bool _hovering = false;
  bool _pressed = false;
  List<int>? _lastRegion;
  Offset? _collapseCenter;

  /// True when the compositor is blurring the desktop behind this window, so
  /// the body can be genuinely translucent instead of a dark rectangle.
  bool _acrylic = false;

  /// Live horizontal offset while the card is being carried. Unbounded and on
  /// the ticker like every other motion here: the hand-rolled Stopwatch loops
  /// this replaced drove the offset through `setState`, which rebuilt the whole
  /// row column — every row, every ring — at pointer rate, on the one gesture
  /// that has to feel glued to the finger.
  late final AnimationController _drag;
  bool _dragging = false;

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
    _channel.setMethodCallHandler(_onNative);
  }

  @override
  void dispose() {
    _life?.cancel();
    _shadowLag?.cancel();
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
        _warmup();
        return null;
      case 'show':
        _show(call.arguments);
        return null;
      case 'reveal':
        return await _reveal();
    }
    return null;
  }

  /// The display changed geometry while this window sat hidden. An engine only
  /// adopts a resize while it is PRESENTING, so this keeps frames flowing while
  /// every pixel stays invisible.
  void _warmup() {
    _resetMotion();
    _warm.forward(from: 0.0);
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
      _acrylic = (args['acrylic'] as bool?) ?? false;
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

  /// Answered AFTER two frames — the reply is what uncloaks the window, so it
  /// must not come back before real pixels exist.
  Future<List<int>?> _reveal() async {
    _resetMotion();
    // Reduce Motion is not a nice-to-have: for someone with vestibular
    // sensitivity a shape springing open is a symptom, not a delight. It still
    // appears, it just appears — no morph, no spring.
    if (MediaQuery.of(context).disableAnimations) {
      _mw.value = 1.0;
      _mh.value = 1.0;
      _shadow.value = 1.0;
    } else {
      _startMorph();
    }
    _armLife();

    await SchedulerBinding.instance.endOfFrame;
    await SchedulerBinding.instance.endOfFrame;
    final r = _hitRect();
    _lastRegion = r;
    return r;
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
  List<int>? _hitRect() {
    final ctx = _cardKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final media = MediaQuery.of(context);
    final dpr = media.devicePixelRatio;
    final o = box.localToGlobal(Offset.zero);
    // Being carried away: the region has to open all the way to the edge of the
    // screen, or the card slides out from under its own window and is sheared
    // off along a hard vertical line — with the shadow cut in half beside it,
    // which is the giveaway. The window's shape is not a decoration; it is
    // where this window exists at all.
    //
    // BOTH edges, because at drag start the direction is not known yet. The
    // band closes again the moment the card settles home — an open region is a
    // full-width invisible window, and it eats every click inside it.
    final travelling = _dragging || _drag.value != 0;
    final left = travelling ? 0.0 : (o.dx - _kPadSide) * dpr;
    final right = travelling
        ? media.size.width * dpr
        : (o.dx + box.size.width + _kPadSide) * dpr;
    return [
      left.floor(),
      ((o.dy - _kPadTop) * dpr).floor(),
      right.ceil(),
      ((o.dy + box.size.height + _kPadBottom) * dpr).ceil(),
      (AppTheme.notifyRadius * dpr).round(),
    ];
  }

  /// The card grows a row, or a row collapses away — the window's shape has to
  /// follow, or the bottom of the card stops taking clicks.
  void _pushRegionAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _leaving) return;
      final r = _hitRect();
      if (r == null) return;
      if (_lastRegion != null && _listEq(_lastRegion!, r)) return;
      _lastRegion = r;
      // .ignore() for the same reason as Sfx (lib/core/sfx/sfx.dart): this
      // engine returns before runZonedGuarded, so a rejectable future left
      // behind here surfaces as an unhandled async error with nobody to catch
      // it. Fire and forget — a shape that fails to update is not fatal.
      _channel.invokeMethod<void>('region', r).ignore();
    });
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

  void _onHover(bool over) {
    _hovering = over;
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
    await Future<void>.delayed(
        AppTheme.notifyTickDrawDuration + AppTheme.notifyDonePause);
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
    setState(() {
      _cards = const [];
      _striking.clear();
      _ringKeys.clear();
      _drag.value = 0.0;
      _pressed = false;
    });
    _lastRegion = null;
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
      ],
    );
  }

  Widget _positioned() {
    // `_cardKey` sits above every animated transform on purpose — the hit
    // region is measured from the resting layout, not from a frame mid-morph.
    final card = SizedBox(
      key: _cardKey,
      width: AppTheme.notifyWidth,
      child: _travelling(),
    );
    switch (kNotifyCorner) {
      case NotifyCorner.bottomRight:
        return Positioned(right: _kEdgeInset, bottom: _kEdgeInset, child: card);
      case NotifyCorner.bottomCenter:
        return Positioned(
          left: 0,
          right: 0,
          bottom: 48,
          child: Center(child: card),
        );
    }
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
        // Open the window's shape BEFORE the card starts moving.
        _pushRegionAfterFrame();
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
              ((col - AppTheme.notifyCollapseFadeStart) /
                      (1.0 - AppTheme.notifyCollapseFadeStart))
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
                acrylic: _acrylic,
                shape: shape,
                shadowShape: shadowShape,
                pressed: _pressed,
                paintKey: _paintKey,
                onHoverChanged: _onHover,
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
