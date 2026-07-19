import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// The home of "no time".
///
/// Aiming at a group inside a day cell can never work: it needs both groups
/// VISIBLE and the cell to have room. An empty day, a day of only-timed tasks
/// and a month cell (two rows) have neither — which is why every boundary we
/// tried fixed one case and broke another.
///
/// So the alternative destination stops being a region and becomes a PLACE, the
/// way Apple Calendar's all-day row is a place: it exists whether or not it
/// holds anything, and you move onto it. The body of the day means "keep the
/// hour" (what every calendar on earth does, so a user who knows nothing can
/// never be surprised); this rail means "any time that day".
///
/// It only exists while a TIMED task is in the air — an untimed one has a single
/// possible destination, so there is nothing to choose — and only on the day the
/// cursor is actually over. Seven rails at once was noise; the choice belongs to
/// the day you are addressing, and it appears the moment you address it.
///
/// It sits at the TOP of the day's task area, right under the day's head, not on
/// the cell's floor: the floor is a long drag away, and "this day, no particular
/// hour" belongs next to the day's identity, not beneath its last row.
///
/// It FLOATS — opaque, shadowed, above the rows. It must not push the day's
/// tasks around: reserving a slot for it made every column twitch downward the
/// instant you picked a card up, which is the cheap version of this idea. A drop
/// target is a layer, not a row.
///
/// Being an overlay is load-bearing, not cosmetic: the boundary is a constant
/// offset from the cell's top, so the preview can never move the line that
/// decides the preview. That closes the flicker/teleport class of bug by
/// construction.
class AnytimeRail extends StatelessWidget {
  /// The cursor is over this day and a timed task is in the air.
  final bool visible;

  /// The cursor is on the rail itself (mode == 'clear').
  final bool armed;
  final double height;

  /// The hour the dragged task is carrying, e.g. '09:30'. Shown being handed
  /// over — "09:30 → Anytime" — because a bare noun never said that the time
  /// would be REMOVED. The rail states the change it makes.
  final String? fromTime;

  const AnytimeRail({
    super.key,
    required this.visible,
    required this.armed,
    this.fromTime,
    this.height = 22,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, -0.35),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          opacity: visible ? 1.0 : 0.0,
          child: _strip(),
        ),
      ),
    );
  }

  Widget _strip() {
    final compact = height < 19;
    final ink = Colors.white.withValues(alpha: armed ? 0.92 : 0.55);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
        // OPAQUE — it floats over the rows, so it may not be see-through, or
        // the titles underneath read straight through the label.
        color: Color.alphaBlend(
          AppTheme.honey.withValues(alpha: armed ? 0.22 : 0.10),
          AppTheme.background,
        ),
        border: Border.all(
          color: AppTheme.honey.withValues(alpha: armed ? 0.70 : 0.35),
          width: armed ? 1.0 : 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
          if (armed)
            const BoxShadow(color: AppTheme.honeyGlow, blurRadius: 12),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The hour, then the hand-over. Seeing 09:30 sitting on the strip that
          // is about to take it is the whole explanation — no verb needed.
          if (fromTime != null && !compact) ...[
            Text(
              fromTime!,
              maxLines: 1,
              style: AppFonts.robotoMono(
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                color: ink.withValues(alpha: ink.a * 0.60),
                decoration: TextDecoration.lineThrough,
                decorationColor: AppTheme.honey.withValues(alpha: 0.75),
                decorationThickness: 1.4,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              compact ? '→ Anytime' : 'Anytime',
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: AppFonts.inter(
                fontSize: compact ? 8.0 : 9.0,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
                color: ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
