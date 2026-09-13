import 'dart:developer' as developer;

/// Thin wrapper around dart:developer's log so every voxa log line is
/// tagged and timestamped consistently, and shows up in `flutter run`
/// console output as well as DevTools.
class Log {
  Log._();

  static void d(String tag, String message) => _emit(tag, message, 500);
  static void i(String tag, String message) => _emit(tag, message, 800);
  static void w(String tag, String message) => _emit(tag, message, 900);

  static void e(String tag, String message, [Object? error, StackTrace? stackTrace]) {
    developer.log(
      message,
      time: DateTime.now(),
      name: 'voxa.$tag',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void _emit(String tag, String message, int level) {
    developer.log(message, time: DateTime.now(), name: 'voxa.$tag', level: level);
  }
}
