---
description: Send events from a Flutter app to simpledatalogs with the simpledatalogs_flutter package.
---

# Flutter

## Install

```sh
flutter pub add simpledatalogs_flutter
```

## Add it

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'package:simpledatalogs_flutter/simpledatalogs_flutter.dart';

Future<void> main() async {
  await SimpleDataLogsFlutter.configure(
    ingestKey: const String.fromEnvironment('SIMPLEDATALOGS_KEY'),
    autocapture: AutocaptureOptions.all,
  );

  runApp(MaterialApp(
    navigatorObservers: [SimpleDataLogsNavigatorObserver()],
    home: const HomePage(),
  ));
}
```

```dart
SimpleDataLogs.track('signup', {'plan': 'pro'});
```

Run with `flutter run --dart-define=SIMPLEDATALOGS_KEY=sdl_pub_…`. Events wait in a crash-safe outbox in the app support folder until a `202`, so nothing is lost if the app is killed.

## In the first minute

- `session_start` and `app_launched` within 30 seconds, or as soon as the app is hidden.
- A `screen_view` for every named route you open.
- With `SimpleDataLogs.setDeviceId(anonymousId)` before `configure`, the device counts in **active devices**.

## Autocapture

`AutocaptureOptions.all` sends launches, sessions (30 minutes away ends one) and uncaught errors as `app_error`. Screen views come from `SimpleDataLogsNavigatorObserver` on named page routes.

## Dart servers

Use the pure Dart package with a disk outbox and a 5-second batch interval:

```sh
dart pub add simpledatalogs
```

```dart
SimpleDataLogs.configure(
  ingestKey: Platform.environment['SIMPLEDATALOGS_KEY']!,
  storage: FileOutboxStorage(Directory('/var/lib/my-app/simpledatalogs')),
  batchInterval: const Duration(seconds: 5),
);
```
