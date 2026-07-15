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
| 1.0.4 | 2026-07-14 22:xx | round-8 real-root fix | Releases\slate_v1.0.4 | `1.0.4` in app.so; registry Run → v1.0.4; matrix 12/12 ×2 now with PIXEL asserts (MAD vs S1 reference) — catches the corner-pill that rect asserts missed. Real root: cold-window swapchain, healed off-screen (_coldMorph) |
