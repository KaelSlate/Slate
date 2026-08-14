/// Single source for the app version stamped into exports and crash logs.
/// Keep in sync with pubspec.yaml `version:`.
///
/// "Keep in sync" is a promise a person makes and forgets: this was still 1.1.7
/// in a bundle whose exe already read 1.1.8+17, because the exe takes its
/// version from pubspec at build time and this does not. The DEPLOYS marker
/// check is what caught it — `1.1.8` ABSENT from app.so while `1.1.7` was
/// FOUND — which is exactly the job that check exists to do.
const String kAppVersion = '1.1.8';
