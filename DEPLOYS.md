# Deploys

Every deploy to `Releases\` gets a line here — version, date, source commit, folder.
Law: after copying the bundle, verify the marker string in `data\app.so` (a string
unique to this build's newest feature), the running process path, and the HKCU Run
registry value. An unrecorded deploy caused a full bug round (round 8: user tested
a 3-day-stale binary).

| Version | Date | Commit | Folder | Marker verified |
|---------|------|--------|--------|-----------------|
| 1.0.0 | 2026-07-09 | pre-git | Releases\slate_v1.0.0 | — |
| 1.0.1 | 2026-07-11 16:22 | pre-git (round 6; round 7 NOT included) | Releases\slate_v1.0.1 | — |
| 1.0.2 | 2026-07-14 10:55 | 9d3f2ac + round-8 WIP | Releases\slate_v1.0.2 | `slate_trace` + `Report a problem` in app.so; registry Run → v1.0.2; DLL hashes 3-way match. Superseded same day by 1.0.3 |
| 1.0.3 | 2026-07-14 15:04 | round-8 commits | Releases\slate_v1.0.3 | Matrix 12/12 — but the matrix only checked Win32 RECTS. The stretched pill was STILL broken: a Win32-correct fullscreen window can present a stale DWM surface. Superseded by 1.0.4 |
| 1.0.4 | 2026-07-14 22:xx | round-8 real-root fix | Releases\slate_v1.0.4 | Correct pill, but entrance animation ran off-screen (looked abrupt). Superseded by 1.0.5 |
| 1.0.5 | 2026-07-14 23:xx | round-8 pill + animation | Releases\slate_v1.0.5 | `1.0.5` in app.so; registry Run → v1.0.5; matrix 12/12 ×2 (pixel asserts). Cold morph's off-screen entrance run heals the swapchain; revealTick RESETS + replays the spring on-screen so the animation is smooth AND the pill is centered. Superseded by 1.0.6 (architecture change) |
| 1.0.6 | 2026-07-15 | separate pill window (18e1c06) | Releases\slate_v1.0.6 | `1.0.6` + `runPillWindow` in app.so; registry Run → v1.0.6; new pill-window matrix 7/7 ×2. ARCHITECTURE: the capture pill is now its own always-on-top window (own Flutter engine) — the main window is NEVER morphed, so the whole rounds 1-8 bug class is gone. +655/−1498 (morph Frankenstein deleted) |
