import 'dart:developer' as developer;

/// How serious one SDK log line is.
enum SdkLogLevel {
  /// Routine detail, e.g. a batch was sent.
  debug,

  /// Something the host should look at, e.g. the outbox dropped old events.
  warning,

  /// A setup mistake, e.g. an invalid key.
  error,
}

/// Receives every SDK log line; replace it to route lines into your own logger.
typedef SdkLogHandler = void Function(SdkLogLevel level, String message);

/// The SDK's single logging door, so nothing ever writes to stdout by surprise.
class SdkLog {
  /// The current handler; defaults to `dart:developer` under the name `simpledatalogs`.
  static SdkLogHandler handler = _logToDeveloperConsole;

  /// Logs routine detail.
  static void debug(String message) => _emit(SdkLogLevel.debug, message);

  /// Logs something the host should look at.
  static void warning(String message) => _emit(SdkLogLevel.warning, message);

  /// Logs a setup mistake.
  static void error(String message) => _emit(SdkLogLevel.error, message);

  // Hands one line to the handler; a throwing handler never reaches the host app.
  static void _emit(SdkLogLevel level, String message) {
    try {
      handler(level, message);
    } catch (_) {
      // Logging must fail open like everything else.
    }
  }

  // The default handler: dart:developer, with levels that match package:logging.
  static void _logToDeveloperConsole(SdkLogLevel level, String message) {
    final developerLevel = switch (level) {
      SdkLogLevel.debug => 500,
      SdkLogLevel.warning => 900,
      SdkLogLevel.error => 1000,
    };

    developer.log(message, name: 'simpledatalogs', level: developerLevel);
  }
}
