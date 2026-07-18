import 'package:flutter/material.dart';

import '../../core/interaction/drag_session.dart';
import '../../core/theme/app_theme.dart';
import '../widgets/hover_task_card.dart' show GlassBorderPainter;

/// The lifted card that follows the cursor. Lives in PulseLayer's root Stack
/// above the inbox drawer. Per-frame work is pure paint: fixed layout at the
/// source size, Transform.scale for lift/morph (filterQuality non-null for the
/// whole visible lifetime — text-hop rule), Positioned offsets under tight
/// constraints so the chrome never re-layouts.
///
/// After landing, a "corpse" copy keeps fading ~130ms while the real card
/// fades in — a crossfade instead of a one-frame flash.
class DragPreviewLayer extends StatefulWidget {
  const DragPreviewLayer({super.key});

  @override
  State<DragPreviewLayer> createState() => _DragPreviewLayerState();
}

class _DragPreviewLayerState extends State<DragPreviewLayer>
    with TickerProviderStateMixin {
  final DragSession _session = DragSession.instance;

  late final AnimationController _lift;
  late final AnimationController _form; // 0 = source shape → 1 = compact pill
  late final AnimationController _trans;
  late final AnimationController _fadeOut;

  Rect? _transFrom;
  double _formAtRelease = 1.0;
  // 'card' | 'block' — the shape the pill un-morphs INTO as it lands (a ribbon
  // drop becomes a block; everything else a card). Spring-back returns to the
  // source's own shape.
  String _landingChrome = 'card';
  DragPayload? _corpsePayload;
  Rect? _corpseRect;
  double _corpseForm = 0.0;
  String _corpseChrome = 'card';

  @override
  void initState() {
    super.initState();
    _lift = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 140),
    );
    _form = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 260));
    _trans = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _fadeOut = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 130));
    _session.addListener(_onPhase);
  }

  @override
  void dispose() {
    _session.removeListener(_onPhase);
    _lift.dispose();
    _form.dispose();
    _trans.dispose();
    _fadeOut.dispose();
    super.dispose();
  }

  static const double _pillH = 34.0;

  /// Carry it at the size it already is. A day-cell card is exactly the size of
  /// the row it will land in, so a day→day flight now has NO resize at all —
  /// it used to condense to 0.6× (clamped to ≥150), which made every carried
  /// card the wrong size and every touchdown a jolt. Height still settles to the
  /// compact row so a taller inbox card eases into its slot instead of snapping.
  Size _pillSize(DragPayload p) {
    final w = p.sourceGlobalRect.width.clamp(120.0, 360.0);
    return Size(w, _pillH);
  }

  double get _formT => Curves.easeOutCubic.transform(_form.value);

  /// Card lifts at the grab point, then condenses into a pill under the
  /// cursor (iOS-style drag stack) — the flight form is the lerp of the two.
  Rect _flightRect() {
    final p = _session.payload!;
    final pointer = _session.pointerGlobal.value;
    final src = p.sourceGlobalRect.size;
    final srcRect = (pointer - p.grabOffset) & src;
    final pill = _pillSize(p);
    final fx =
        src.width <= 0 ? 0.5 : (p.grabOffset.dx / src.width).clamp(0.0, 1.0);
    final fy =
        src.height <= 0 ? 0.5 : (p.grabOffset.dy / src.height).clamp(0.0, 1.0);
    final pillRect =
        (pointer - Offset(fx * pill.width, fy * pill.height)) & pill;
    return Rect.lerp(srcRect, pillRect, _formT)!;
  }

  void _onPhase() {
    if (!mounted) return;
    switch (_session.phase) {
      case DragPhase.active:
        _trans.value = 0.0;
        _lift.forward(from: 0.0);
        _form.forward(from: 0.0);
        break;
      case DragPhase.settling:
      case DragPhase.springingBack:
        final settling = _session.phase == DragPhase.settling;
        _transFrom = _flightRect();
        _formAtRelease = _formT;
        // Un-morph into the destination shape: a ribbon drop lands as a block,
        // everything else as a card; a spring-back returns to the source shape.
        _landingChrome = settling
            ? _session.landingChrome
            : (_session.payload?.kind == DragSourceKind.timelineBlock
                ? 'block'
                : 'card');
        _form.stop();
        // Longer settle so the pill visibly re-expands into its slot instead
        // of snapping — this is the "перетекание", not a cut.
        _trans.duration =
            Duration(milliseconds: settling ? 300 : 280);
        _lift.reverse();
        final payload = _session.payload;
        final chrome = _landingChrome;
        _trans.forward(from: 0.0).whenComplete(() {
          if (!mounted) return;
          _corpsePayload = payload;
          _corpseRect = _session.liveSettleTarget ?? _transFrom;
          _corpseForm = 0.0; // fully un-morphed by now
          _corpseChrome = chrome;
          _session.finishTransition();
          _fadeOut.forward(from: 0.0).whenComplete(() {
            if (!mounted) return;
            setState(() {
              _corpsePayload = null;
              _corpseRect = null;
            });
          });
        });
        break;
      case DragPhase.idle:
        break;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final phase = _session.phase;
    final hasLive = phase != DragPhase.idle && _session.payload != null;
    final hasCorpse = _corpsePayload != null && _corpseRect != null;
    if (!hasLive && !hasCorpse) return const SizedBox.shrink();

    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge(
                [_session.pointerGlobal, _lift, _form, _trans, _fadeOut]),
            builder: (context, _) {
              final box = context.findRenderObject() as RenderBox?;
              final children = <Widget>[];
              if (hasCorpse) {
                _addMorphLayers(
                  children,
                  box,
                  _corpsePayload!,
                  _corpseRect!,
                  form: _corpseForm,
                  lift: 0.0,
                  opacity: 1.0 - Curves.easeOut.transform(_fadeOut.value),
                  landing: _corpseChrome,
                );
              }
              if (hasLive) {
                Rect rect;
                double form;
                String landing;
                if (phase == DragPhase.active) {
                  rect = _flightRect();
                  form = _formT;
                  // While flying, keep the source's own shape under the pill.
                  landing = _session.payload!.kind ==
                          DragSourceKind.timelineBlock
                      ? 'block'
                      : 'card';
                } else {
                  final transT = Curves.easeOutCubic.transform(_trans.value);
                  final from = _transFrom ?? _flightRect();
                  // Chase the LIVE destination rect — it may still be moving
                  // (a drawer sliding home, a list reflowing) as we land.
                  final to = _session.liveSettleTarget ?? from;
                  rect = Rect.lerp(from, to, transT)!;
                  // Pill (form=1) re-expands into the destination shape (form=0)
                  // in lockstep with the flight — the "перетекание".
                  form = _formAtRelease * (1.0 - transT);
                  landing = _landingChrome;
                }
                _addMorphLayers(children, box, _session.payload!, rect,
                    form: form, lift: _lift.value, opacity: 1.0,
                    landing: landing);
              }
              return Stack(clipBehavior: Clip.none, children: children);
            },
          ),
        ),
      ),
    );
  }

  /// One morphing box, two chromes: the shaped chrome (source while lifting,
  /// destination while landing) fades against the compact pill — both scaled
  /// onto the same lerped rect. [landing] picks the shaped chrome: 'block' for
  /// a ribbon slot, 'card' otherwise.
  void _addMorphLayers(List<Widget> out, RenderBox? box, DragPayload payload,
      Rect globalRect,
      {required double form,
      required double lift,
      required double opacity,
      required String landing}) {
    final asBlock = landing == 'block';
    // Natural size for the shaped chrome: a block lands ~36px tall, so scaling
    // its chrome from a card-sized natural would distort the text. Use a
    // block-proportioned natural when landing as a block.
    final shapedNatural = asBlock
        ? Size(payload.sourceGlobalRect.width, 36.0)
        : payload.sourceGlobalRect.size;
    out.add(_chromeLayer(box, globalRect, shapedNatural,
        _DragCardChrome(payload: payload, lift: lift, asBlock: asBlock),
        opacity: opacity * (1.0 - form), lift: lift));
    out.add(_chromeLayer(box, globalRect, _pillSize(payload),
        _DragPillChrome(payload: payload, lift: lift),
        opacity: opacity * form, lift: lift));
  }

  Widget _chromeLayer(
      RenderBox? box, Rect globalRect, Size natural, Widget chrome,
      {required double opacity, required double lift}) {
    if (opacity <= 0.004) return const SizedBox.shrink();
    // Lift swells the box around its center (≤3%) and still lands EXACTLY on
    // the settle rect once the lift has reversed to 0.
    final s = 1.0 + 0.03 * lift;
    final lifted = Rect.fromCenter(
      center: globalRect.center,
      width: globalRect.width * s,
      height: globalRect.height * s,
    );
    final topLeft =
        box == null ? lifted.topLeft : box.globalToLocal(lifted.topLeft);
    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      width: natural.width,
      height: natural.height,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.scale(
          scaleX: lifted.width / natural.width,
          scaleY: lifted.height / natural.height,
          alignment: Alignment.topLeft,
          filterQuality: FilterQuality.low,
          child: chrome,
        ),
      ),
    );
  }
}

/// Compact flight form — the card condenses into this pill under the cursor
/// (accent dot + title + time), then the pill morphs into the landing slot.
class _DragPillChrome extends StatelessWidget {
  final DragPayload payload;
  final double lift;

  const _DragPillChrome({required this.payload, required this.lift});

  Color get _accent {
    switch (payload.task.priority) {
      case 2:
        return AppTheme.priorityCritical;
      case 1:
        return AppTheme.priorityHigh;
      default:
        return AppTheme.priorityNormal;
    }
  }

  String _fmtTime(int m) =>
      '${((m ~/ 60) % 24).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final task = payload.task;
    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            Colors.white.withOpacity(0.10), AppTheme.background),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: Colors.white.withOpacity(0.16),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.30 + 0.15 * lift),
            blurRadius: 14 + 10 * lift,
            offset: Offset(0, 5 + 4 * lift),
          ),
          BoxShadow(
            color: _accent.withOpacity(0.12 * lift),
            blurRadius: 16,
            spreadRadius: -2,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 13),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _accent,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.white.withOpacity(0.92),
                letterSpacing: 0.1,
              ),
            ),
          ),
          if (task.startTime != null) ...[
            const SizedBox(width: 6),
            Text(
              _fmtTime(task.startTime!),
              style: AppFonts.robotoMono(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: Colors.white.withOpacity(0.50),
                letterSpacing: 0.2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Static, near-opaque replica of a task card — no hover/edit machinery.
/// [asBlock] forces the compact ribbon-block look regardless of the payload's
/// source, so an inbox card landing on the timeline morphs into a block.
class _DragCardChrome extends StatelessWidget {
  final DragPayload payload;
  final double lift;
  final bool asBlock;

  const _DragCardChrome(
      {required this.payload, required this.lift, this.asBlock = false});

  Color get _accent {
    switch (payload.task.priority) {
      case 2:
        return AppTheme.priorityCritical;
      case 1:
        return AppTheme.priorityHigh;
      default:
        return AppTheme.priorityNormal;
    }
  }

  String _fmtTime(int m) =>
      '${((m ~/ 60) % 24).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (asBlock || payload.kind == DragSourceKind.timelineBlock) {
      return _buildBlockChrome();
    }
    return _buildCardChrome();
  }

  // Replica of _TaskBlock's resting look (rounded 6, accent glass) — opaque
  // base so the floating preview never reads as see-through.
  Widget _buildBlockChrome() {
    final task = payload.task;
    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(_accent.withOpacity(0.22), AppTheme.background),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _accent.withOpacity(0.45), width: 0.75),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25 + 0.20 * lift),
            blurRadius: 10 + 12 * lift,
            offset: Offset(0, 3 + 5 * lift),
          ),
          BoxShadow(
            color: _accent.withOpacity(0.14 * lift),
            blurRadius: 14,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Flexible(
              child: Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withOpacity(0.92),
                  letterSpacing: 0.05,
                ),
              ),
            ),
            if (task.startTime != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Container(
                  width: 2.5,
                  height: 2.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _accent.withOpacity(0.55),
                  ),
                ),
              ),
              Text(
                _fmtTime(task.startTime!),
                style: AppFonts.robotoMono(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withOpacity(0.45),
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCardChrome() {
    final task = payload.task;
    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            Colors.white.withOpacity(0.08), AppTheme.background),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25 + 0.20 * lift),
            blurRadius: 12 + 14 * lift,
            offset: Offset(0, 4 + 6 * lift),
          ),
          BoxShadow(
            color: _accent.withOpacity(0.10 * lift),
            blurRadius: 18,
            spreadRadius: -2,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: CustomPaint(
        foregroundPainter: GlassBorderPainter(
          radius: 10,
          colors: [
            Colors.white.withOpacity(0.20),
            Colors.white.withOpacity(0.06),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withOpacity(0.20),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (task.startTime != null) ...[
                        Text(
                          _fmtTime(task.startTime!),
                          style: AppFonts.robotoMono(
                            fontSize: 10,
                            color: Colors.white.withOpacity(0.50),
                            letterSpacing: 0.2,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          task.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Colors.white.withOpacity(0.92),
                            letterSpacing: 0.1,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(width: 2.5, color: _accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
