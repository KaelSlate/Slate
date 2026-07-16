import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/engine/spatial_zoom_engine.dart';
import '../../core/interaction/drag_session.dart';
import '../../core/state/lesson_state.dart';
import '../../core/theme/app_theme.dart';

/// ONE line, bottom centre. Never two, never a cheat-sheet.
///
/// Replaces the old hint strip, which dumped six shortcuts at once
/// («C add · Alt+Space capture · V month · I inbox · Ctrl+scroll zoom · ↑↓
/// weeks») and then died wholesale on the first capture — so a user who caught
/// one thought into the inbox was never taught anything again.
///
/// Accelerators are pushed here by the action that earns them; invites are
/// pulled from the current context, so they exist only while their moment does.
/// See [LessonState] for why those are two different things.
class CoachWhisper extends StatefulWidget {
  /// Whether the current overview has anything to drag. An invite to drag with
  /// an empty week would be an invite to do nothing.
  final bool hasTasks;

  const CoachWhisper({super.key, required this.hasTasks});

  @override
  State<CoachWhisper> createState() => _CoachWhisperState();
}

class _CoachWhisperState extends State<CoachWhisper> {
  /// An accelerator is a notification about what just happened — it says its
  /// piece and leaves. An invite has no timer: it stands while its moment does.
  static const _accelLife = Duration(seconds: 6);

  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    LessonState.instance.addListener(_onLessons);
    // Also here, not only in the listener: a lesson offered while this widget
    // was between mounts would otherwise never get a timer, and an accelerator
    // with no timer never leaves.
    _onLessons();
  }

  @override
  void dispose() {
    _expiry?.cancel();
    LessonState.instance.removeListener(_onLessons);
    super.dispose();
  }

  void _onLessons() {
    _expiry?.cancel();
    final l = LessonState.instance.pushed;
    if (l != null) {
      _expiry = Timer(_accelLife, () => LessonState.instance.clearPushed(l));
    }
    if (mounted) setState(() {});
  }

  /// The whole ladder, in one place. Accelerator beats invite: it is tied to an
  /// action the user took a second ago, and it expires — an invite can wait.
  Lesson? _resolve() {
    // Someone else already owns the user's attention.
    if (StaircaseState.isWelcoming || StaircaseState.isWarmingUp) return null;
    if (StaircaseState.isComposingTask) return null;
    // Mid-drag the drop badge is doing the talking — two voices, one moment.
    if (DragSession.instance.isActive) return null;

    final ls = LessonState.instance;

    final pushed = ls.pushed;
    if (pushed != null && !ls.isLearned(pushed.id)) return pushed;

    // Invites live in the overviews only; the day view is somewhere you already
    // arrived, so there is nothing left to invite you to.
    if (StaircaseState.currentLevel == StaircaseLevel.day) return null;

    if (!ls.isLearned(Lessons.zoom.id)) {
      return ls.inviteAvailable(Lessons.zoom) ? Lessons.zoom : null;
    }
    // Ordered by dependency, not by script: don't invite someone to drag a task
    // between days before they have ever opened one.
    if (widget.hasTasks && ls.inviteAvailable(Lessons.drag)) return Lessons.drag;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final lesson = _resolve();
    if (lesson != null && lesson.kind == LessonKind.invite) {
      // Counted when it REACHES the screen, not when it is considered.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        LessonState.instance.noteInviteShown(lesson);
      });
    }
    return Positioned(
      left: 0,
      right: 0,
      bottom: 16,
      child: IgnorePointer(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 450),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: lesson == null
              ? const SizedBox(key: ValueKey('none'), height: 14)
              : _line(lesson),
        ),
      ),
    );
  }

  /// Same two-tone the hint strip used — the head carries the key or the move,
  /// the tail the outcome. One visual language for anything Slate teaches.
  Widget _line(Lesson lesson) {
    final i = lesson.text.indexOf(' — ');
    final head = i < 0 ? lesson.text : lesson.text.substring(0, i);
    final tail = i < 0 ? null : lesson.text.substring(i + 3);
    return Row(
      key: ValueKey(lesson.id),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text.rich(TextSpan(children: [
          TextSpan(
            text: head,
            style: AppFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.30),
              letterSpacing: 0.5,
            ),
          ),
          if (tail != null)
            TextSpan(
              text: '  $tail',
              style: AppFonts.inter(
                fontSize: 10.5,
                color: Colors.white.withValues(alpha: 0.17),
                letterSpacing: 0.3,
              ),
            ),
        ])),
      ],
    );
  }
}
