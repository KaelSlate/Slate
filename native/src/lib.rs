pub mod api;
pub mod types;
pub mod spatial;
pub mod ghost;
pub mod local_db;
pub mod sync_engine;
pub mod nlp_parser;

/// Debug-only logging. In release builds (`debug_assertions` off) the constant-false
/// branch is eliminated at compile time — no stderr output, no user data / server
/// response bodies leaking into logs, format strings stripped from the binary.
/// Args are still type-checked in both modes (no unused-variable warnings).
#[macro_export]
macro_rules! dlog {
    ($($t:tt)*) => {
        if cfg!(debug_assertions) {
            eprintln!($($t)*);
        }
    };
}
