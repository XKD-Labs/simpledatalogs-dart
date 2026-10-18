# simpledatalogs_flutter

Flutter wiring for [simpledatalogs](https://simpledatalogs.com), on top of the pure Dart [`simpledatalogs`](https://pub.dev/packages/simpledatalogs) package:

- a crash-safe outbox in the app support folder (via `path_provider`; memory on the web);
- a flush whenever the app is hidden, and sessions that follow the foreground;
- uncaught Flutter and platform errors as `app_error`, when you ask for them;
- `SimpleDataLogsNavigatorObserver` for screen views.

## Install

```sh
flutter pub add simpledatalogs_flutter
```

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:simpledatalogs_flutter/simpledatalogs_flutter.dart';

Future<void> main() async {
  SimpleDataLogs.setEnabled(userAllowsUsageStatistics);
  await SimpleDataLogsFlutter.configure(ingestKey: 'sdl_pub_…', autocapture: AutocaptureOptions.all);

  runApp(MaterialApp(
    navigatorObservers: [SimpleDataLogsNavigatorObserver()],
    home: const HomePage(),
  ));
}
```

Then `SimpleDataLogs.track('level_complete', {'level': 3})` anywhere. This package re-exports the whole core API.

The full README, with the API table, autocapture, privacy and how the SDK behaves, is in the [repository](https://github.com/XKD-Labs/simpledatalogs-dart#readme).
