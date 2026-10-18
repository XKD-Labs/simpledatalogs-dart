/// Track events and errors from Dart and Flutter with simpledatalogs.
///
/// Start with `SimpleDataLogs.configure`, then call `SimpleDataLogs.track`.
library;

export 'src/outbox_storage.dart' show OutboxStorage, MemoryOutboxStorage;
export 'src/sdk_log.dart' show SdkLog, SdkLogLevel, SdkLogHandler;
export 'src/session_tracker.dart' show AutocaptureOptions;
export 'src/simpledatalogs_client.dart' show SimpleDataLogsClient;
export 'src/simpledatalogs_facade.dart' show SimpleDataLogs;
