import 'package:http/http.dart' as http;

import 'outbox_storage.dart';
import 'sdk_log.dart';
import 'session_tracker.dart';
import 'simpledatalogs_client.dart';
import 'version.dart' as version;

/// The public entry point: configure once at launch, then track events from anywhere.
abstract final class SimpleDataLogs {
  /// This SDK's version, sent in every User-Agent.
  static const String sdkVersion = version.sdkVersion;

  /// The production ingest host.
  static Uri get defaultEndpoint => version.defaultEndpoint;

  /// The one running client, set by `configure`.
  static SimpleDataLogsClient? _client;

  /// The opt-out set before `configure`, applied when it runs.
  static bool _isEnabled = true;

  /// The device id set before `configure`.
  static String? _deviceId;

  /// Default properties set before `configure`.
  static Map<String, Object?> _defaultProperties = const {};

  /// The running client, for lifecycle wiring and advanced use; null before `configure`.
  static SimpleDataLogsClient? get client => _client;

  /// Starts the SDK; call once at launch, after `setEnabled` if the user may have opted out.
  ///
  /// Pass a `FileOutboxStorage` (from `package:simpledatalogs/io.dart`) to keep events across restarts.
  /// Servers should pass `batchInterval: Duration(seconds: 5)`.
  static void configure({
    required String ingestKey,
    Uri? endpoint,
    AutocaptureOptions autocapture = AutocaptureOptions.none,
    OutboxStorage? storage,
    Duration batchInterval = defaultBatchInterval,
    http.Client? httpClient,
  }) {
    // The first configuration stays in effect.
    if (_client != null) {
      SdkLog.warning('SimpleDataLogs.configure was called again; the first configuration stays in effect');
      return;
    }

    // In-memory storage loses events on a crash, so say so once.
    if (storage == null) {
      SdkLog.debug('No outbox storage given; events are kept in memory only');
    }

    _client = SimpleDataLogsClient(
      ingestKey: ingestKey,
      endpoint: endpoint,
      storage: storage,
      autocapture: autocapture,
      batchInterval: batchInterval,
      isEnabled: _isEnabled,
      deviceId: _deviceId,
      defaultProperties: _defaultProperties,
      httpClient: httpClient,
    );
  }

  /// Records one event; it returns at once, and never throws or blocks the caller.
  static void track(String eventName, [Map<String, Object?> properties = const {}]) {
    final runningClient = _client;

    // Tracking before configure is a setup bug worth a log line.
    if (runningClient == null) {
      SdkLog.error('track($eventName) was called before SimpleDataLogs.configure; event dropped');
      return;
    }

    runningClient.track(eventName, properties);
  }

  /// Records a screen view (`screen_view` with a `screen` prop).
  static void trackScreen(String screenName, [Map<String, Object?> properties = const {}]) {
    track('screen_view', {...properties, 'screen': screenName});
  }

  /// Records an error as `app_error`, rate limited per message.
  static void trackError(Object error, [StackTrace? stackTrace, Map<String, Object?> properties = const {}]) {
    _client?.trackError(error, stackTrace, properties);
  }

  /// Sets the anonymous device id attached to every later event, or clears it with null.
  static void setDeviceId(String? deviceId) {
    _deviceId = deviceId;
    _client?.setDeviceId(deviceId);
  }

  /// Replaces the properties merged into every later event, e.g. app_version, platform.
  static void setDefaultProperties(Map<String, Object?> properties) {
    _defaultProperties = Map.of(properties);
    _client?.setDefaultProperties(properties);
  }

  /// Turns collection on or off; turning it off also deletes every event not yet delivered.
  static void setEnabled(bool isEnabled) {
    _isEnabled = isEnabled;
    _client?.setEnabled(isEnabled);
  }

  /// Sends everything tracked so far; completes when that attempt ends, keeping anything undelivered.
  static Future<void> flush() async {
    await _client?.flush();
  }

  /// Stops the SDK's timers so a script can exit; undelivered events stay in the outbox.
  static Future<void> close() async {
    final runningClient = _client;
    _client = null;

    await runningClient?.close();
  }
}
