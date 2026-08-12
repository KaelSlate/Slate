# Reminder card — snapshot around the 12 Aug 2026 polish pass

`before/` is the card as it stood at the start of the session.
`after/` is the card as it shipped out of it.

Neither folder is built. `analysis_options.yaml` excludes `archive/**` because
these files live outside `lib/` and their relative imports cannot resolve.

## How `before/` was produced — read this before trusting it

**These files were never in git.** `lib/notify_window.dart`,
`lib/ui/widgets/reminder_card.dart` and `windows/runner/notify_window.cpp` were
untracked, VS Code's local history had no entries for them, and there was no
stash, `.bak` or `.orig`. So `before/` is not a copy pulled off disk — it is
`after/` with every edit of the session reversed by hand, one at a time.

That reversal is deterministic (each edit was an exact literal replacement, and
all of them are listed below), but it has not been compiled. Treat `before/` as
a faithful reference, not as a guaranteed byte-for-byte original.

**The real fix is that this can never happen again: commit the card files.**

## To roll a single change back

Find it below, open the same region in `before/`, and copy it over. The changes
are independent except where noted.

## What changed

### Correctness

| # | Change | Files |
|---|---|---|
| 1 | `region` method channel implemented natively — it was declared on the Dart side, called from three places, and fell through to `NotImplemented()`. Rows below the first stopped taking clicks; a flicked card was sheared along a hard vertical line. | `notify_window.cpp`, `notify_window.dart` |
| 2 | Flick made symmetric; the hit region now opens **both** edges while dragging, and `_settleBack` closes it again. **Must ship with #1** — without the close, a released drag leaves a full-width invisible window eating clicks. | `notify_window.dart` |
| 3 | Drag moved onto `AnimationController.unbounded`; both hand-rolled `Stopwatch`/`addPostFrameCallback` loops deleted. `setState` per pointer frame had been rebuilding the whole row column. | `notify_window.dart` |
| 4 | Flick flight raced against a 600 ms deadline — the old `if (t > 0.6) break` sat after the `await` and could not fire. | `notify_window.dart` |
| 5 | Reduce Motion narrowed: the flick gesture stays (WCAG 2.3.3 exempts motion essential to functionality), only the overshoot goes. | `notify_window.dart` |

### Sound

| # | Change | Files |
|---|---|---|
| 6 | `IDR_SFX_DUE` added to `Runner.rc`. It was declared in `resource.h` but never mapped, so the reminder had been falling back to the completion clip at a higher gain. | `Runner.rc` |
| 7 | `reminder.wav` added — `D:\SFX\UI\uisfx\zen\seek.mp3`, `volume=6.461dB`, 44100 Hz mono 16-bit, peak exactly −6.00 dBFS. | `windows/runner/resources/sfx/` |
| 8 | `_dueGain` 0.52 → 0.60. The clip sounds for 124 ms against the done clip's 262 ms and the ear integrates loudness over ~150–200 ms, so equal RMS is heard quieter. | `sfx.dart` |
| 9 | The probe harness now rings. It calls `notify_sink_` directly and bypasses `ReminderScheduler`, which is the only caller of `chime()` — so it had been silent by construction. | `flutter_window.cpp` |

### Material

| # | Change | Files |
|---|---|---|
| 10 | Acrylic body 0.58 → 0.72. At 0.58 the title measured 3.8 : 1 over a light document, under WCAG AA's 4.5 : 1. 0.72 gives 5.6 : 1. | `app_theme.dart`, `reminder_card.dart` |
| 11 | Dark outer edge added — black 0.28, width 1.0, even all round, on the outset path, drawn first. The rim had three light strokes and no dark boundary at all. | `app_theme.dart`, `reminder_card.dart` |
| 12 | Even hairline 0.09 → 0.14; top rim 0.42 → 0.50 at rest, 0.66 → 0.72 hovered. Only legible once #11 sits under it. | `app_theme.dart`, `reminder_card.dart` |
| 13 | **All pointer-tracking light removed** — the surface specular pool and the rim lens. macOS banners do not respond to cursor position; the travelling highlight is a visionOS/tvOS idiom. Side effect: body and rim no longer depend on pointer position, so the card stops repainting on mouse move. | `app_theme.dart`, `reminder_card.dart` |

### Design and motion

| # | Change | Files |
|---|---|---|
| 14 | Priority dot, 5 px, before the time, only for `!` and `!!`; time weight w600 when set. Presence and weight are non-chromatic channels. Closes the standing TODO in the theme. | `app_theme.dart`, `reminder_card.dart` |
| 15 | Hover reverse curve fixed — `easeOutCubic` was applied to the raw controller value, so the exit played the curve backwards (eased *in*). Now `CurvedAnimation` with `reverseCurve: easeOutCubic.flipped`. | `reminder_card.dart` |
| 16 | Press feedback 150 ms → 100 ms, Apple's published figure. The ring beside it was already at 90. | `app_theme.dart` |
| 17 | `AppTheme.taskDone` introduced; the green was written out eight times across three files. | `app_theme.dart`, `reminder_card.dart`, `hover_task_card.dart`, `quiet_progress_ring.dart` |

### Deliberately NOT changed

Entrance springs (stiffness 503.6, ζ 0.740 / 0.900), the ring's release damping
(bounce 0.38 ≈ one pixel of overshoot on an 18 px ring), and `notifyRadius = 16`.
All three are defended by measurement and pinned by `reminder_card_motion_test.dart`.

### Still open

The 3D tilt on hover is **not** a macOS banner idiom — banners do not tilt. It
survived this pass because it was liked, not because it matched the reference.
It is the same class of decision as #13, and it is undecided.
