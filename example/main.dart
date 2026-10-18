import 'dart:io';

import 'package:simpledatalogs/io.dart';
import 'package:simpledatalogs/simpledatalogs.dart';

/// Sends two events from a Dart script, then flushes before exiting.
Future<void> main() async {
  // A public key from your project's Keys page; servers may use a secret sdl_sec_ key.
  final ingestKey = Platform.environment['SIMPLEDATALOGS_KEY'] ?? 'sdl_pub_replace_me';

  // Keep the outbox on disk, so events survive a crash; servers flush every ~5 s.
  SimpleDataLogs.configure(
    ingestKey: ingestKey,
    storage: FileOutboxStorage(Directory('.simpledatalogs')),
    batchInterval: const Duration(seconds: 5),
  );

  SimpleDataLogs.setDefaultProperties({'app_version': '1.0.0', 'platform': Platform.operatingSystem});
  SimpleDataLogs.track('report_generated', {'rows': 120, 'format': 'csv'});

  // A script sends before it exits; anything undelivered stays on disk for the next run.
  await SimpleDataLogs.flush();
  await SimpleDataLogs.close();
}
