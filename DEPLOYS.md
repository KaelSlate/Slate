# Deploys

Every deploy to `Releases\` gets a line here — version, date, source commit, folder.
Law: after copying the bundle, verify the marker string in `data\app.so` (a string
unique to this build's newest feature), the running process path, and the HKCU Run
registry value. An unrecorded deploy caused a full bug round (round 8: user tested
a 3-day-stale binary).

Law (public builds, added 2026-07-20): any build that leaves this machine is made
with `flutter build windows --release --obfuscate --split-debug-info=symbols\v<ver>`
and the `symbols\v<ver>` folder is KEPT (git-ignored, never deleted) — without it
tester crash logs are unreadable. The Rust DLL is already stripped (`strip=true`).
Local/dev deploys may skip obfuscation; the DEPLOYS line must then say so.

| Version | Date | Commit | Folder | Marker verified |
|---------|------|--------|--------|-----------------|
| 1.0.0 | 2026-07-09 | pre-git | Releases\slate_v1.0.0 | — |
| 1.0.1 | 2026-07-11 16:22 | pre-git (round 6; round 7 NOT included) | Releases\slate_v1.0.1 | — |
| 1.0.2 | 2026-07-14 10:55 | 9d3f2ac + round-8 WIP | Releases\slate_v1.0.2 | `slate_trace` + `Report a problem` in app.so; registry Run → v1.0.2; DLL hashes 3-way match. Superseded same day by 1.0.3 |
| 1.0.3 | 2026-07-14 15:04 | round-8 commits | Releases\slate_v1.0.3 | Matrix 12/12 — but the matrix only checked Win32 RECTS. The stretched pill was STILL broken: a Win32-correct fullscreen window can present a stale DWM surface. Superseded by 1.0.4 |
| 1.0.4 | 2026-07-14 22:xx | round-8 real-root fix | Releases\slate_v1.0.4 | Correct pill, but entrance animation ran off-screen (looked abrupt). Superseded by 1.0.5 |
| 1.0.5 | 2026-07-14 23:xx | round-8 pill + animation | Releases\slate_v1.0.5 | `1.0.5` in app.so; registry Run → v1.0.5; matrix 12/12 ×2 (pixel asserts). Cold morph's off-screen entrance run heals the swapchain; revealTick RESETS + replays the spring on-screen so the animation is smooth AND the pill is centered. Superseded by 1.0.6 (architecture change) |
| 1.0.6 | 2026-07-15 | separate pill window (18e1c06) | Releases\slate_v1.0.6 | `1.0.6` + `runPillWindow` in app.so; registry Run → v1.0.6; new pill-window matrix 7/7 ×2. ARCHITECTURE: the capture pill is now its own always-on-top window (own Flutter engine) — the main window is NEVER morphed, so the whole rounds 1-8 bug class is gone. +655/−1498 (morph Frankenstein deleted) |
| 1.0.6 (re-cut) | 2026-07-15 later | tray + maximize hotfixes | Releases\slate_v1.0.6 | Same version at user's request; two hotfixes on top: (1) pill window registers ONLY flutter_acrylic (its 2nd tray_manager was fighting the main one → tray icon went unclickable); (2) maximize button re-reads real Win32 state on onWindowResize + delayed recheck (minimize-from-max → restore desynced the icon). Verify by build timestamp, not version string |
| 1.0.7 | 2026-07-20 | audit-fix wave (5fd5d70, 3780a3b) + prefs-resurrection fix | Releases\slate_v1.0.7 | Markers `1.0.7` + `Gym at 6pm #health` (hints) + `can't open your tasks` (VaultGate) in app.so; DLL 3-way hash match (root/target/bundle); registry Run → v1.0.7 --hidden. NOT obfuscated (local deploy, per law note). Contents: EN parser (5pm/at 5/from-to/slang), VaultGate + typed init codes + capture spill, AppData home + Documents migration, daily backups ×7, teaching placeholders, honest hotkey fallback, WM_ENDSESSION flush, atomic prefs; legacy secure-storage prefs migration REMOVED (it resurrected onboarded/welcomed after a wipe — user saw no welcome). Visual acceptance of VaultGate/placeholders/welcome-fallback pending |
| 1.1.0 | 2026-07-20 | 0bf0a92 (runner/UI) + 6e9a319 (day pane) | Releases\slate_v1.1.0 | **MVP release build — OBFUSCATED**; `symbols\v1.1.0\app.windows-x64.symbols` KEPT (2.6 MB — without it tester crash logs are unreadable; never delete, and it only decodes THIS build). Markers in app.so: `ANYTIME` and `1.1.0` FOUND, `TO SCHEDULE` **ABSENT** — the negative marker is the proof the new code actually shipped. DLL 3-way hash match (root/target/bundle). Registry Run → v1.1.0 --hidden (was 1.0.7). analyze 0 errors / 0 warnings; tests 106/106. Contents: the day's left pane now speaks "show the future" (DropFuture) like week/month and is ONE Anytime destination — the keep/clear split and the grey drop-wash are deleted, taking with them the invisible 40% boundary on days with no untimed tasks; TO SCHEDULE → ANYTIME; struck-through hour hand-over on the group head. Also: white launch flash fixed (window-class brush + first frame off the raster thread + lazy PillWindow), month pixel-snapping, Esc no longer swallowed on week/month, zoom invite no longer seals the lesson ladder. NOT code-signed — the SmartScreen wall still stands for strangers: fine for wave 0 (hand-installed), a blocker for wave 1. VISUAL ACCEPTANCE PENDING |
