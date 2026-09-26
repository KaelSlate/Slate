> **Status: Archived / Educational Case Study**  
> 18 releases over 10 weeks (July–September 2026). Kept as a technical reference and an honest post-mortem.

https://github.com/KaelSlate/Slate/raw/main/here-ezgif.com-mute-video.mp4

https://github.com/KaelSlate/Slate/raw/main/main.mp4

# Slate — Local-First Windows Task Capture Engine

Press **Alt + Space** anywhere on Windows. Type `"gym tomorrow at 6pm"`. Hit Enter. The task lands on a spatial timeline — no browser, no account, no cloud. Two seconds from thought to plan.

![Quick capture](slate_shot_capture.png)

## Architecture

```
Flutter Desktop (UI, 120 FPS)
        │
        │  FFI — zero-copy, #[repr(C)] structs
        ▼
Rust Core (slate_core.dll)
  ├── NLP date/time parser (EN + UA)
  ├── Spatial layout engine
  ├── SQLCipher (AES-256-GCM, encrypted at rest)
  └── Sync engine (stubbed, never shipped)
```

| Layer | Stack |
|---|---|
| UI | Flutter 3.x, Riverpod, custom pill window (separate engine) |
| Core | Rust → cdylib via dart:ffi, Rayon for parallelism |
| Storage | SQLite + SQLCipher, daily auto-backups (×7) |
| Platform | window_manager, flutter_acrylic, hotkey_manager, tray_manager, launch_at_startup |
| Distribution | Inno Setup installer + portable ZIP, landing on GitHub Pages |

## Key Features

- Global hotkey capture pill (Alt+Space → transparent overlay → NLP → task)
- Natural-language parsing: `"call mom Friday at 5pm"`, `"dentist next week"`
- Day / week / month spatial timeline with drag-and-drop
- Encrypted local-only storage — your data never leaves your machine
- Desktop reminder notifications
- 116 tests, obfuscated release builds

## Key Lesson

This project was an engineering exploration of high-performance desktop architecture under Windows — Flutter + Rust FFI, zero-copy interop, encrypted local storage, spatial UI at 120 FPS, custom NLP. As a technical exercise, it delivered everything it set out to build.

**Lesson learned: Don't over-engineer an MVP with complex database encryption, a custom NLP parser, and a second Flutter engine before validating basic market demand.** The first real user proved that a planner without push notifications and a phone app doesn't survive past day one — no matter how fast or encrypted it is. Build the habit loop first, optimize later.

## License

MIT. See [LICENSE](LICENSE).
