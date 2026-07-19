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

  const AnytimeRail({
    super.key,
    required this.visible,
    required this.armed,
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(compact ? 6 : 8),
        color: AppTheme.honey.withValues(alpha: armed ? 0.12 : 0.04),
        border: Border.all(
          color: AppTheme.honey.withValues(alpha: armed ? 0.55 : 0.30),
          width: armed ? 1.0 : 0.5,
        ),
        boxShadow: armed
            ? const [BoxShadow(color: AppTheme.honeyGlow, blurRadius: 10)]
            : null,
      ),
      child: Text(
        'Anytime',
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: AppFonts.inter(
          fontSize: compact ? 8.0 : 9.0,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.4,
          color: Colors.white.withValues(alpha: armed ? 0.85 : 0.45),
        ),
      ),
    );
  }
}
