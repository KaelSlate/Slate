import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/engine/slate_core_bridge.dart';
import '../../core/interaction/delete_settle.dart';
import '../../core/interaction/drag_session.dart';
import '../overlays/task_peek_layer.dart';

/// Slate — HoverTaskCard v3.0 Premium
/// Priority left border (2px accent bar). Pill tags (Slate Blue).
/// No drag-handle dots. Spring-physics hover lift. Animated strike-through.

Color _cardPriorityColor(int priority) {
  switch (priority) {
    case 2: return AppTheme.priorityCritical;
    case 1: return AppTheme.priorityHigh;
    default: return Colors.white.withOpacity(0.07); // barely visible for normal
  }
}

Color _cardPriorityAccent(int priority) {
  switch (priority) {
    case 2: return AppTheme.priorityCritical;
    case 1: return AppTheme.priorityHigh;
    default: return AppTheme.priorityNormal;
  }
}

class HoverTaskCard extends StatefulWidget {
  final RustTask task;
  final bool compact;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onDelete;
  final ValueChanged<String>? onEditTitle;
  /// Hover-dwell peek of the full title. Off in the month cell, where the
  /// cell-level day peek already reveals every task in full.
  final bool enablePeek;
  /// Render the title in full (wrap, no ellipsis/fade, no fixed compact height).
  /// Used INSIDE the peek popover, where the whole point is to read everything.
  final bool fullTitle;

  const HoverTaskCard({
    super.key,
    required this.task,
    this.compact = false,
    this.onTap,
    this.onLongPress,
    this.onDelete,
    this.onEditTitle,
    this.enablePeek = true,
    this.fullTitle = false,
  });

  @override
  State<HoverTaskCard> createState() => _HoverTaskCardState();
}

class _HoverTaskCardState extends State<HoverTaskCard>
    with TickerProviderStateMixin {
  bool _hovered = false;
  // Set during title layout; the peek gate reads it lazily at fire time.
  bool _titleOverflows = false;
  late AnimationController _strikeCtrl;
  late Animation<double> _strike;
  late AnimationController _hoverCtrl;
  late Animation<double> _hoverAnim;

  bool _isEditing = false;
  bool _isDeleting = false;
  late TextEditingController _titleController;
  late FocusNode _focusNode;
  late AnimationController _deleteCtrl;

  @override
  void initState() {
    super.initState();
    _deleteCtrl = AnimationController(
        duration: const Duration(milliseconds: 260), vsync: this, value: 1.0);
    _strikeCtrl = AnimationController(
        duration: const Duration(milliseconds: 320), vsync: this);
    _strike = CurvedAnimation(parent: _strikeCtrl, curve: Curves.easeOut);
    if (widget.task.isCompleted) _strikeCtrl.value = 1.0;

    _hoverCtrl = AnimationController(
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 80),
      vsync: this,
    );
    _hoverAnim = CurvedAnimation(parent: _hoverCtrl, curve: Curves.easeOut);

    _titleController = TextEditingController(text: widget.task.title);
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus && _isEditing) {
        setState(() {
          _isEditing = false;
          _titleController.text = widget.task.title;
        });
      }
    });
  }

  @override
  void didUpdateWidget(HoverTaskCard old) {
    super.didUpdateWidget(old);
    if (widget.task.isCompleted && !old.task.isCompleted) _strikeCtrl.forward();
    if (!widget.task.isCompleted && old.task.isCompleted) _strikeCtrl.reverse();
    if (widget.task.title != old.task.title && !_isEditing) {
      _titleController.text = widget.task.title;
    }
  }

  @override
  void dispose() {
    // Safety: a card torn down mid-collapse (view switch) must not leave its id
    // marked, or that row stays excluded from the list's capacity forever.
    if (_isDeleting) DeleteSettle.unmarkDeleting(widget.task.id);
    _strikeCtrl.dispose();
    _hoverCtrl.dispose();
    _titleController.dispose();
    _focusNode.dispose();
    _deleteCtrl.dispose();
    super.dispose();
  }

  void _triggerDelete() async {
    if (_isDeleting || widget.onDelete == null) return;
    setState(() => _isDeleting = true);
    // Publish the id NOW, not in 260ms: lists drop it from their capacity
    // immediately, so the next card is promoted and glides up DURING this
    // collapse instead of popping in after it. See DeleteSettle.deleting.
    DeleteSettle.markDeleting(widget.task.id);
    _deleteCtrl.reverse();
    await Future.delayed(const Duration(milliseconds: 260));
    if (mounted && widget.onDelete != null) widget.onDelete!();
  }

  void _onEnter(_) {
    // A drag in flight owns the pointer — resting cards must not light up
    // under the payload as it passes over them.
    if (DragSession.hoverSuppressed) return;
    setState(() => _hovered = true);
    _hoverCtrl.forward();
  }

  void _onExit(_) {
    setState(() => _hovered = false);
    _hoverCtrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final done = widget.task.isCompleted;
    final priority = widget.task.priority;
    final priorityBorderColor = _cardPriorityColor(priority);
    final priorityAccent = _cardPriorityAccent(priority);

    // Premium dismiss: as _deleteCtrl runs 1→0 the row rolls up from its top edge
    // (axisAlignment -1 → neighbours glide up into the gap), fades, and slips a touch
    // to the left. One coherent motion, no abrupt snap when the data finally drops.
    final Widget card = SizeTransition(
      sizeFactor: CurvedAnimation(parent: _deleteCtrl, curve: Curves.easeInOutCubic),
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: CurvedAnimation(parent: _deleteCtrl, curve: Curves.easeIn),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-0.12, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: _deleteCtrl, curve: Curves.easeOutCubic)),
          child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: _onEnter,
          onExit: _onExit,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            // While a delete's collapse is settling, the row under the cursor
            // is mid-glide — a spam click must not strike it by accident.
            onTap: () {
              if (DeleteSettle.settling) return;
              widget.onTap?.call();
            },
            onLongPress: widget.onLongPress,
            child: AnimatedBuilder(
              animation: _hoverAnim,
              builder: (context, child) {
                final shadowBlur = 5.0 + _hoverAnim.value * 11.0;
                final shadowOpacity = 0.12 + _hoverAnim.value * 0.23;
                final shadowY = 2.0 + _hoverAnim.value * 2.0;

                return Container(
                    margin: EdgeInsets.only(bottom: widget.compact ? 4 : 5),
                    decoration: BoxDecoration(
                      // Denser fill compensates for the removed per-card blur so
                      // the row still reads as a raised glass surface over the panel.
                      color: Colors.white.withOpacity(done ? 0.035 : 0.07),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: _hovered && !done
                          ? [
                              BoxShadow(
                                color: Colors.black.withOpacity(shadowOpacity),
                                blurRadius: shadowBlur,
                                offset: Offset(0, shadowY),
                              ),
                              // Ambient color-coded priority shadow glow underneath card
                              BoxShadow(
                                color: priorityAccent.withOpacity(0.08),
                                blurRadius: 14,
                                spreadRadius: -2,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.12),
                                blurRadius: 5,
                                offset: const Offset(0, 2),
                              ),
                            ],
                    ),
                    child: child,
                  );
              },
              child: _buildCardContent(done, priority, priorityBorderColor),
            ),
          ),
        ),
        ),
      ),
    );
    if (!widget.enablePeek) return card;
    // Full title on hover-dwell — only when it actually overflows. Interactive:
    // the peek carries the real toggle/edit/delete so you can act from it.
    return PeekHoverGate(
      canShow: () => _titleOverflows,
      maxWidth: 300,
      contentBuilder: (_) => PeekContent.cardTitle(
        widget.task,
        onToggle: widget.onTap,
        onDelete: widget.onDelete,
        onEditTitle: widget.onEditTitle,
      ),
      child: card,
    );
  }

  Widget _buildCardContent(bool done, int priority, Color priorityBorderColor) {
    final vPad = widget.compact ? 9.0 : 12.0;
    final hPad = widget.compact ? 12.0 : 14.0;
    final fSize = widget.compact ? 11.5 : 13.0;

    // ONE weight for every task. Priority already speaks through the left accent
    // bar (wider for !!) and a touch more contrast below — bolding the title too
    // made important tasks shout in a list that should read as one calm voice.
    final FontWeight titleWeight =
        done ? FontWeight.w300 : FontWeight.w400;

    final titleOpacity = done
        ? 0.22
        : (_hovered ? 0.95 : (priority >= 2 ? 0.88 : 0.72));

    return CustomPaint(
      foregroundPainter: GlassBorderPainter(
        radius: 10,
        colors: [
          Colors.white.withOpacity(done ? 0.04 : (0.10 + _hoverAnim.value * 0.15)), // real-time interactive highlight
          Colors.white.withOpacity(0.04),
        ],
      ),
      // Flat translucent surface — no per-card live BackdropFilter. The blur
      // sampled an empty backdrop for a frame under entrance/opacity and re-sampled
      // on list re-sort (strike-through) → background flash. Container glass depth
      // now lives in ONE static blur behind the whole panel. Big FPS win too.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
          // Card content. Compact rows are FIXED height — the week/month cell
          // capacity math counts on 34px, so the hover icons (19px incl. their
          // tap padding) must never inflate the row.
          SizedBox(
            height: (widget.compact && !widget.fullTitle) ? 34 : null,
            child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: hPad,
                vertical: (widget.compact && !widget.fullTitle)
                    ? 0
                    : (widget.compact ? 7 : vPad)),
            child: Row(
              crossAxisAlignment: widget.fullTitle
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
            // ──── Checkbox (animated ring) ────
            AnimatedScale(
              scale: done ? 1.0 : (_hovered ? 1.06 : 1.0),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutBack,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: widget.compact ? 16 : 18,
                height: widget.compact ? 16 : 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done
                      ? const Color(0xFF30D158).withOpacity(0.12)
                      : Colors.transparent,
                  border: Border.all(
                    color: done
                        ? const Color(0xFF30D158).withOpacity(0.60)
                        : Colors.white.withOpacity(_hovered ? 0.28 : 0.12),
                    width: done ? 1.5 : 1.0,
                  ),
                  boxShadow: done
                      ? [
                          BoxShadow(
                            color: const Color(0xFF30D158).withOpacity(0.25),
                            blurRadius: 8,
                          ),
                        ]
                      : (_hovered ? [
                          BoxShadow(
                            color: priorityBorderColor.withOpacity(0.20),
                            blurRadius: 5,
                          )
                        ] : []),
                ),
                child: done
                    ? Icon(Icons.check,
                        size: widget.compact ? 9 : 10,
                        color: const Color(0xFF30D158).withOpacity(0.95))
                    : null,
              ),
            ),
            SizedBox(width: widget.compact ? 8 : 10),

            // ──── Time badge + separator (scheduled only, non-compact) ────
            if (widget.task.startTime != null && !widget.compact) ...[
              Text(
                _fmtTimeRange(widget.task.startTime!, widget.task.endTime),
                style: AppFonts.robotoMono(
                  fontSize: 10,
                  color: Colors.white.withOpacity(_hovered ? 0.60 : 0.42),
                  letterSpacing: 0.2,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Container(
                width: 0.5,
                height: 12,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: Colors.white.withOpacity(0.08),
              ),
            ] else if (widget.task.startTime != null && widget.compact) ...[
              Text(
                _fmtTimeIntra(widget.task.startTime!),
                style: AppFonts.robotoMono(
                  fontSize: 9.5,
                  color: Colors.white.withOpacity(0.68), // premium legibility enhancement
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(width: 5),
            ],

            // ──── Title ────
            Expanded(
              child: _isEditing
                  ? TextField(
                      controller: _titleController,
                      focusNode: _focusNode,
                      mouseCursor: SystemMouseCursors.text,
                      style: AppFonts.inter(
                        fontSize: fSize,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                        letterSpacing: 0.1,
                        height: 1.35,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                      ),
                      onSubmitted: (val) {
                        setState(() => _isEditing = false);
                        if (val.trim().isNotEmpty && widget.onEditTitle != null) {
                          widget.onEditTitle!(val);
                        } else {
                          _titleController.text = widget.task.title;
                        }
                      },
                    )
                  : Row(
                      children: [
                        Flexible(
                          child: AnimatedBuilder(
                            animation: _strike,
                            builder: (ctx, child) => CustomPaint(
                              foregroundPainter: _StrikePainter(
                                  _strike.value,
                                  Colors.white.withOpacity(0.28)),
                              child: child,
                            ),
                            child: _buildTitleText(fSize, titleWeight, titleOpacity),
                          ),
                        ),
                        // ──── Tags ────
                        // Not in a dense overview row: a chip eats ~55px of a
                        // ~180px week/month card, crushing the title it is
                        // supposed to annotate. The overview answers "what and
                        // when"; tags live in the day view and the hover peek.
                        if (widget.task.tags.isNotEmpty &&
                            (!widget.compact || widget.fullTitle)) ...[
                          const SizedBox(width: 8),
                          ...widget.task.tags.map((t) => Container(
                                margin: const EdgeInsets.only(right: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.tagColor.withOpacity(0.10),
                                  borderRadius: BorderRadius.circular(100),
                                  border: Border.all(
                                    color: AppTheme.tagColor.withOpacity(0.22),
                                    width: 0.5,
                                  ),
                                ),
                                child: Text(
                                  '#$t',
                                  style: AppFonts.inter(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.tagColor.withOpacity(0.80),
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              )),
                        ],
                      ],
                    ),
            ),

              ],
            ),
            ),
          ),
          // ──── Quick-action icons — OVERLAY the trailing edge (hover only) ──
          // In-flow they reserved ~42px even while invisible, squeezing the
          // title on narrow week columns. As a Positioned strip with its own
          // fade scrim they cost the title ZERO width at rest and slide in over
          // the (already faded) tail on hover.
          _buildHoverActions(hPad),
          // Priority bar — left strip, wider for !!
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: (!done && priority == 2) ? 3.5 : 2.5,
              decoration: BoxDecoration(
                color: done
                    ? Colors.white.withOpacity(0.05)
                    : priorityBorderColor,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

  // Single-line titles dissolve into the edge (soft ShaderMask) instead of a
  // hard "…". 2-line (day list) keeps ellipsis — a horizontal fade would wrongly
  // dim a full first line that legitimately wraps.
  Widget _buildTitleText(double fSize, FontWeight weight, double opacity) {
    final maxLines = widget.compact ? 1 : 2;
    final style = AppFonts.inter(
      fontSize: fSize,
      fontWeight: weight,
      color: Colors.white.withOpacity(opacity),
      letterSpacing: 0.1,
      height: 1.35,
    );
    // Inside the peek: show the whole thing, wrapped, no fade/ellipsis.
    if (widget.fullTitle) {
      return Text(widget.task.title, softWrap: true, style: style);
    }
    return LayoutBuilder(
      builder: (context, c) {
        final tp = TextPainter(
          text: TextSpan(text: widget.task.title, style: style),
          maxLines: maxLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: c.maxWidth);
        final overflows = tp.didExceedMaxLines;
        if (overflows != _titleOverflows) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _titleOverflows = overflows;
          });
        }
        final text = Text(
          widget.task.title,
          maxLines: maxLines,
          softWrap: maxLines > 1,
          overflow: maxLines == 1 ? TextOverflow.clip : TextOverflow.ellipsis,
          style: style,
        );
        if (!overflows || maxLines != 1) return text;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) {
            final start = rect.width <= 20 ? 0.0 : (rect.width - 18) / rect.width;
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [Colors.white, Colors.white, Colors.transparent],
              stops: [0.0, start, 1.0],
            ).createShader(rect);
          },
          child: text,
        );
      },
    );
  }

  // Edit/delete icons as a right-edge overlay + fade scrim: zero title width at
  // rest, sliding in as a little "shelf" on hover.
  Widget _buildHoverActions(double hPad) {
    final hasEdit = widget.onEditTitle != null;
    final hasDelete = widget.onDelete != null;
    if (!hasEdit && !hasDelete) return const SizedBox.shrink();
    final show = _hovered && !_isEditing;
    final iconSize = widget.compact ? 11.0 : 13.0;
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !show,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          opacity: show ? 1.0 : 0.0,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 140),
            offset: Offset(show ? 0 : 0.3, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 22,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        AppTheme.surface.withOpacity(0.0),
                        AppTheme.surface.withOpacity(0.88),
                      ],
                    ),
                  ),
                ),
                Container(
                  color: AppTheme.surface.withOpacity(0.88),
                  padding: EdgeInsets.only(right: hPad - 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasEdit)
                        _quickActionIcon(
                          Icons.edit_outlined,
                          size: iconSize,
                          onTap: () {
                            setState(() => _isEditing = true);
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _focusNode.requestFocus();
                            });
                          },
                        ),
                      if (hasEdit && hasDelete) const SizedBox(width: 4),
                      if (hasDelete)
                        _quickActionIcon(
                          Icons.delete_outline_rounded,
                          size: iconSize,
                          onTap: () => _triggerDelete(),
                          isDestructive: true,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _quickActionIcon(IconData icon,
      {double size = 13,
      VoidCallback? onTap,
      bool isDestructive = false}) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: size,
            color: isDestructive
                ? Colors.red.withOpacity(0.65)
                : Colors.white.withOpacity(0.45),
          ),
        ),
      ),
    );
  }

  String _fmtTimeIntra(int minutesSinceMidnight) {
    final h = (minutesSinceMidnight ~/ 60) % 24; // > 1440 = past midnight
    final m = minutesSinceMidnight % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  String _fmtTimeRange(int startMins, int? endMins) {
    final s = _fmtTimeIntra(startMins);
    if (endMins == null || endMins == startMins + 60) return s;
    return '$s–${_fmtTimeIntra(endMins)}';
  }
}

// ── Animated Strike-Through Painter ──────────────────────────────

class _StrikePainter extends CustomPainter {
  final double progress;
  final Color color;
  _StrikePainter(this.progress, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width * progress, size.height / 2),
      Paint()
        ..color = color
        ..strokeWidth = 1.0
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_StrikePainter old) => old.progress != progress;
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS BORDER PAINTER
// ═══════════════════════════════════════════════════════════════════════════

class GlassBorderPainter extends CustomPainter {
  final double radius;
  final List<Color> colors;
  final List<double>? stops;
  final double strokeWidth;

  GlassBorderPainter({
    required this.radius,
    required this.colors,
    this.stops,
    this.strokeWidth = 0.8,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
        stops: stops,
      ).createShader(rect);

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(GlassBorderPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth ||
      // Compare list CONTENTS, not identity. The colors list is rebuilt fresh on
      // every parent rebuild (e.g. the whole day view rebuilds on each task toggle
      // via the riverpod Consumer), so identity `!=` was ALWAYS true → the border
      // re-rasterised on every toggle and its anti-aliasing shifted = the header's
      // "border tone changes / zebra shimmer". listEquals → repaint only on a real
      // colour/stop change. (No RepaintBoundary can fix a painter that repaints
      // itself; this is the actual root cause.)
      !listEquals(oldDelegate.colors, colors) ||
      !listEquals(oldDelegate.stops, stops);
}
