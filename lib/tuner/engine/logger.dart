import 'dart:developer' as dev;

/// Lightweight logger used across the tuner module.
/// Uses `dart:developer` so it can be filtered in Observatory/DevTools.
/// Logging is disabled by default; enable via [TunerLogger.enabled].
class TunerLogger {
  TunerLogger._();

  static bool enabled = false;

  static void d(String message, {String name = 'tuner'}) {
    if (!enabled) return;
    dev.log(message, name: name, level: 800); // info level
  }
}
