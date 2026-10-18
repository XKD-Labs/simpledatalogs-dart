import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:simpledatalogs/simpledatalogs.dart';

import 'default_storage_web.dart' if (dart.library.io) 'default_storage_io.dart' as default_storage;

/// Configures simpledatalogs for a Flutter app: a disk outbox, flushes on background, sessions and errors.
abstract final class SimpleDataLogsFlutter {
  /// Forwards app lifecycle changes to sessions and flushes.
  static AppLifecycleListener? _lifecycleListener;

  /// True once the error hooks are installed, so a second call never chains them twice.
  static bool _hasInstalledErrorHooks = false;

  /// Starts the SDK; call once in `main`, after `SimpleDataLogs.setEnabled` if the user may have opted out.
  static Future<void> configure({
    required String ingestKey,
    Uri? endpoint,
    AutocaptureOptions autocapture = AutocaptureOptions.none,
    http.Client? httpClient,
  }) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      _warnAboutSuspiciousKey(ingestKey.trim());

      // Keep the outbox in the app support folder; fall back to memory where there is none.
      final outboxStorage = await _resolveStorage();

      SimpleDataLogs.configure(
        ingestKey: ingestKey,
        endpoint: endpoint,
        autocapture: autocapture,
        storage: outboxStorage,
        httpClient: httpClient,
      );

      // Flush when the app is hidden, and keep sessions in step with the foreground.
      _lifecycleListener ??= AppLifecycleListener(
        onShow: () => SimpleDataLogs.client?.appBecameActive(),
        onHide: () => unawaited(SimpleDataLogs.client?.appWentToBackground()),
      );

      // Uncaught Flutter and platform errors, on request.
      if (autocapture.errors) {
        _installErrorHooks();
      }
    } catch (configureError) {
      SdkLog.error('SimpleDataLogsFlutter.configure failed: $configureError');
    }
  }

  // The platform's outbox storage, or memory when the platform folder is unavailable.
  static Future<OutboxStorage?> _resolveStorage() async {
    try {
      return await default_storage.makeDefaultStorage();
    } catch (storageError) {
      SdkLog.warning('No app support folder ($storageError); events are kept in memory only');
      return null;
    }
  }

  // Sends uncaught errors as app_error, after the handlers that were there before.
  static void _installErrorHooks() {
    if (_hasInstalledErrorHooks) {
      return;
    }

    _hasInstalledErrorHooks = true;

    // Errors inside the Flutter framework: build, layout, paint and gestures.
    final previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (errorDetails) {
      previousFlutterErrorHandler?.call(errorDetails);
      SimpleDataLogs.trackError(errorDetails.exception, errorDetails.stack, {'source': 'flutter'});
    };

    // Errors outside the framework, e.g. an uncaught Future error.
    final previousPlatformErrorHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      SimpleDataLogs.trackError(error, stackTrace, {'source': 'platform'});
      return previousPlatformErrorHandler?.call(error, stackTrace) ?? false;
    };
  }

  // Logs a secret key, which belongs on servers only.
  static void _warnAboutSuspiciousKey(String ingestKey) {
    if (ingestKey.startsWith('sdl_sec_')) {
      SdkLog.warning('A secret sdl_sec_ key was configured; apps should ship a public sdl_pub_ key');
    }
  }
}
