import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/spatial_zoom_engine.dart';
import 'package:slate/core/state/lesson_state.dart';
import 'package:slate/ui/overlays/coach_whisper.dart';

/// The teaching ladder: one line at a time, each mechanic retiring on its OWN
/// mastery. The bug this replaces: a single `hintsActive` bool gated every hint
/// and died on the first capture, so catching one thought into the inbox
/// silently switched off zoom, drag and everything else the user hadn't learned.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ls = LessonState.instance;

  setUp(() {
    ls.debugReset();
    StaircaseState.isWelcoming = false;
    StaircaseState.isWarmingUp = false;
    StaircaseState.isComposingTask = false;
    StaircaseState.currentLevel = StaircaseLevel.weekTactics;
  });

  group('LessonState', () {
    test('a lesson retires on its own mastery, and only its own', () {
      ls.learn(Lessons.zoom.id);
      expect(ls.isLearned(Lessons.zoom.id), isTrue);
      for (final other in Lessons.all.where((l) => l.id != Lessons.zoom.id)) {
        expect(ls.isLearned(other.id), isFalse,
            reason: 'learning zoom must not touch ${other.id}');
      }
    });

    test('a learned lesson can never be offered again', () {
      ls.learn(Lessons.viewKey.id);
      ls.offer(Lessons.viewKey);
      expect(ls.pushed, isNull);
    });

    test('learning the pushed lesson clears the slot', () {
      ls.offer(Lessons.inboxKey);
      expect(ls.pushed, Lessons.inboxKey);
      ls.learn(Lessons.inboxKey.id);
      expect(ls.pushed, isNull);
    });

    test('clearing an expired accelerator does NOT learn it', () {
      ls.offer(Lessons.backKey);
      ls.clearPushed(Lessons.backKey);
      expect(ls.pushed, isNull);
      expect(ls.isLearned(Lessons.backKey.id), isFalse,
          reason: 'it was shown, not performed — it may earn the slot again');
    });

    test('an invite gives up after its sightings budget — never nags', () {
      expect(ls.inviteAvailable(Lessons.drag), isTrue);
      // One sighting per session, however many times it is asked for.
      ls.noteInviteShown(Lessons.drag);
      ls.noteInviteShown(Lessons.drag);
      ls.noteInviteShown(Lessons.drag);
      expect(ls.inviteAvailable(Lessons.drag), isTrue,
          reason: 'that was one session, not three');

      // Three separate sessions.
      for (var i = 0; i < 2; i++) {
        ls.debugNewSession();
        ls.noteInviteShown(Lessons.drag);
      }
      expect(ls.inviteAvailable(Lessons.drag), isFalse);
    });

    test('every lesson text carries the house em-dash split', () {
      for (final l in Lessons.all) {
        expect(l.text, contains(' — '), reason: '${l.id} breaks the voice');
      }
    });
  });

  group('CoachWhisper', () {
    /// Settles past the 450ms switcher — mid-fade the outgoing line is still in
    /// the tree, and asserting during it would test the animation, not the rule.
    Future<void> pump(WidgetTester tester, {bool hasTasks = true}) async {
      await tester.pumpWidget(MaterialApp(
        home: Stack(children: [CoachWhisper(hasTasks: hasTasks)]),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('shows the zoom invite first, and nothing else with it',
        (tester) async {
      await pump(tester);
      expect(find.textContaining('Ctrl + scroll'), findsOneWidget);
      expect(find.textContaining('drag'), findsNothing,
          reason: 'ONE line — never a cheat-sheet');
    });

    testWidgets('opening a day retires the invite and it never returns',
        (tester) async {
      await pump(tester);
      expect(find.textContaining('Ctrl + scroll'), findsOneWidget);

      ls.learn(Lessons.zoom.id);
      await pump(tester);
      expect(find.textContaining('Ctrl + scroll'), findsNothing);
    });

    testWidgets('drag is only invited AFTER a day has been opened',
        (tester) async {
      await pump(tester);
      expect(find.textContaining('drag'), findsNothing,
          reason: 'ordered by dependency: no day opened yet');

      ls.learn(Lessons.zoom.id);
      await pump(tester);
      expect(find.textContaining('drag'), findsOneWidget);
    });

    testWidgets('a zoom invite that gives up steps aside — it must not seal '
        'the ladder behind it', (tester) async {
      // Someone who never touches the wheel: zoom spends its whole budget and
      // stays UNLEARNED forever. Gating the rest on zoom being learned meant
      // the drag invite could never be reached by this user, ever.
      for (var i = 0; i < 3; i++) {
        ls.debugNewSession();
        await pump(tester);
      }
      expect(ls.isLearned(Lessons.zoom.id), isFalse);
      expect(ls.inviteAvailable(Lessons.zoom), isFalse, reason: 'budget spent');

      await pump(tester);
      expect(find.textContaining('Ctrl + scroll'), findsNothing,
          reason: 'it gave up — no nagging');
      expect(find.textContaining('drag'), findsOneWidget,
          reason: 'the ladder moves on');
    });

    testWidgets('no drag invite when there is nothing to drag', (tester) async {
      ls.learn(Lessons.zoom.id);
      await pump(tester, hasTasks: false);
      expect(find.textContaining('drag'), findsNothing);
    });

    testWidgets('an accelerator outranks a live invite', (tester) async {
      await pump(tester);
      expect(find.textContaining('Ctrl + scroll'), findsOneWidget);

      ls.offer(Lessons.inboxKey);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('opens the inbox'), findsOneWidget);
      expect(find.textContaining('Ctrl + scroll'), findsNothing,
          reason: 'still one line');
    });

    testWidgets('the coach stays silent while something else is talking',
        (tester) async {
      StaircaseState.isWelcoming = true;
      await pump(tester);
      expect(find.textContaining('Ctrl + scroll'), findsNothing);

      StaircaseState.isWelcoming = false;
      StaircaseState.isComposingTask = true;
      await pump(tester);
      expect(find.textContaining('Ctrl + scroll'), findsNothing,
          reason: 'a pill is open — do not talk over it');
    });

    testWidgets('no invites in the day view — you already arrived',
        (tester) async {
      StaircaseState.currentLevel = StaircaseLevel.day;
      await pump(tester);
      expect(find.textContaining('Ctrl + scroll'), findsNothing);
    });

    testWidgets('an accelerator expires on its own', (tester) async {
      ls.learn(Lessons.zoom.id);
      ls.learn(Lessons.drag.id); // silence the invites
      ls.offer(Lessons.viewKey);
      await pump(tester);
      expect(find.textContaining('flips week and month'), findsOneWidget);

      await tester.pump(const Duration(seconds: 7));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('flips week and month'), findsNothing,
          reason: 'it says its piece and leaves');
    });
  });
}
