# Slate window-morph e2e harness

The regression matrix distilled from morph rounds 1-8. Committed on purpose:
the rounds 1-7 scripts lived outside the repo and were lost, costing a full
re-investigation.

## Run

```
powershell -NoProfile -File tools\e2e\run_matrix.ps1
powershell -NoProfile -File tools\e2e\run_matrix.ps1 -Exe Releases\slate_v1.0.3\slate.exe
powershell -NoProfile -File tools\e2e\run_matrix.ps1 -Scenario S5,S6
```

Never launch via `-EncodedCommand` or with `Bypass` flags (AV heuristics).
The run drives the REAL desktop for ~2 minutes: it launches Slate (newest-wins
handover replaces a running instance), opens Notepad as the foreign window, and
sends global hotkeys. Warn the user first. On exit it leaves the deployed Slate
resident in the tray.

## Matrix

| # | Prior state | Key dismissal checks |
|---|-------------|----------------------|
| S1 | windowed, focused | back at R0, never hidden, no intermediate rect (atomic) |
| S2 | windowed, behind Notepad | below Notepad, Notepad focused, no above-Notepad flash |
| S3 | maximized, focused (in-app path) | window rect/flags never change |
| S4 | maximized, behind Notepad | re-maximized below Notepad, no zoomed-above flash |
| S5 | minimized from windowed | re-minimized, rcNormal kept, no uncloaked flash |
| S6 | minimized from maximized (bug-1 repro) | WPF_RESTORETOMAXIMIZED kept, restore -> maximized |
| S7 | tray-hidden from windowed | zero visible flashes; ShowRequested open -> front |
| S8 | tray-hidden from maximized (round-7 repro) | pill full work area; open -> maximized |
| L1 | fresh launch over focused Notepad | foreground + above Notepad |
| L2 | second launch, newest-wins handover | old pid gone <=6s, new front |
| L3 | dismiss-over-Notepad, then ShowRequested open | front (bug-2 core) |
| SR1 | soak 5xS2 + 5xS5 + hotkey-mid-restore | invariants hold, pending summon replays |

## Limits

- Rect / z-order / cloak-attribute assertions work even in a headless session.
  Pixel-level truth (what DWM actually composited) does not - a visual flash
  that the flag sampler cannot see needs the user's eye or PrintWindow
  screenshots in an interactive session.
- The in-app pill (S3) is invisible to Win32 - the scenario only asserts the
  window is untouched.
- `Slate.ShowRequested` (registered window message) drives the exact tray-click
  code path (`TrayShell.openApp`); a real tray-icon click is not scriptable.
- Release builds swallow debugPrint: morph branch/atomic evidence comes from the
  in-app trace ring - tray "Report a problem" writes slate_trace.txt.
