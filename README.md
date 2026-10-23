# simpledatalogs for Dart and Flutter

Track events from Flutter apps, Dart servers and scripts with [simpledatalogs](https://simpledatalogs.com), and see them as counters and charts.

- Two packages from this repository:
  - [`simpledatalogs`](https://pub.dev/packages/simpledatalogs): the pure Dart core. Works on the Dart VM, Flutter (mobile, desktop, web) and servers. One dependency: `http`.
  - [`simpledatalogs_flutter`](https://pub.dev/packages/simpledatalogs_flutter): optional Flutter wiring. A disk outbox in the app support folder (via `path_provider`), flushes on background, sessions, error capture and screen views.
- Follows every [sender rule](https://simpledatalogs.com/docs/api/sender-rules) of the ingest API.
- Full guide: [simpledatalogs.com/docs](https://simpledatalogs.com/docs).

## Install

Flutter apps:

```sh
flutter pub add simpledatalogs_flutter
```

Dart servers and scripts:

```sh
dart pub add simpledatalogs
```

## Quick start (Flutter)

```dart
import 'package:flutter/material.dart';
import 'package:simpledatalogs_flutter/simpledatalogs_flutter.dart';

Future<void> main() async {
  // The opt-out first, then identity and default properties, then the key.
  SimpleDataLogs.setEnabled(userAllowsUsageStatistics);
  SimpleDataLogs.setDeviceId(anonymousDeviceId);
  SimpleDataLogs.setDefaultProperties({'app_version': '1.1.0'});

  await SimpleDataLogsFlutter.configure(
    ingestKey: 'sdl_pub_…',
    autocapture: AutocaptureOptions.all,
  );

  runApp(MaterialApp(
    navigatorObservers: [SimpleDataLogsNavigatorObserver()],
    home: const HomePage(),
  ));
}
```

Then, anywhere (it returns at once and never throws):

```dart
SimpleDataLogs.track('level_complete', {'level': 3, 'duration_s': 42});
```

## Quick start (Dart server or script)

```dart
import 'dart:io';

import 'package:simpledatalogs/io.dart';
import 'package:simpledatalogs/simpledatalogs.dart';

Future<void> main() async {
  SimpleDataLogs.configure(
    ingestKey: Platform.environment['SIMPLEDATALOGS_KEY']!,
    storage: FileOutboxStorage(Directory('/var/lib/my-app/simpledatalogs')),
    batchInterval: const Duration(seconds: 5),
  );

  SimpleDataLogs.track('report_generated', {'rows': 120});

  // Scripts send before exiting; anything undelivered stays on disk for the next run.
  await SimpleDataLogs.flush();
  await SimpleDataLogs.close();
}
```

Servers may use a secret `sdl_sec_…` key. Apps must ship a public `sdl_pub_…` key; the Flutter package logs a warning for a secret one.
To send to another ingest endpoint, such as a local one, pass `endpoint: Uri.parse('http://localhost:4001')`.

## API

| Call | What it does |
|---|---|
| `SimpleDataLogsFlutter.configure(ingestKey:, endpoint:, autocapture:)` | Flutter: starts the SDK with a disk outbox and lifecycle flushes. Later calls are ignored. |
| `SimpleDataLogs.configure(ingestKey:, endpoint:, autocapture:, storage:, batchInterval:)` | Pure Dart: starts the SDK once. `storage` defaults to memory; pass `FileOutboxStorage` to survive restarts. `batchInterval` defaults to 10 s in release builds and 5 s in debug (use ~5 s on servers). |
| `track(eventName, [properties])` | Records one event. `event_id` and `ts` are stamped now, when the event happens. |
| `trackScreen(screenName, [properties])` | Records `screen_view` with a `screen` prop. |
| `trackError(error, [stackTrace, properties])` | Records `app_error` (`exception_type`, `message`, `stack`), at most 5 per message and 50 per run. |
| `setDeviceId(id)` | Sets (or clears, with `null`) the `device_id` on every later event. |
| `setDefaultProperties(map)` | Replaces the properties merged into every event's `props`; the event's own properties win. |
| `setEnabled(bool)` | The opt-out. `false` ignores new events and **deletes every unsent event**; `true` collects again. |
| `flush()` | Seals and sends everything now; completes when that attempt ends. Undelivered events stay in the outbox. |
| `close()` | Stops timers so a script can exit. |

Property values are strings, integers, finite doubles or booleans. Anything else (null, NaN, lists, maps) is dropped with a log line.
For several keys in one process, create `SimpleDataLogsClient` instances directly; they take the same arguments.

Call `setEnabled` **before** `configure`. A user who opted out then never sends a byte, and whatever an earlier run left on disk is deleted instead of sent. The SDK does not persist the opt-out: pass your app's setting on every launch.

## Autocapture

Off until you pass it.

| Option | What you get |
|---|---|
| `appLaunches` | `app_launched` once per `configure`, with `is_first_launch` |
| `sessions` | `session_start`, a `session_id` on every event, and `session_end` (`duration_s`) once the app has been away 30 minutes; a relaunch within 30 minutes resumes the session |
| `errors` | With the Flutter package, uncaught Flutter and platform errors as `app_error` (`source` = `flutter` or `platform`), after your own handlers |

`AutocaptureOptions.all` is all three; pick with `AutocaptureOptions(sessions: true, errors: true)`.

- **Screen views:** add `SimpleDataLogsNavigatorObserver()` to `navigatorObservers`. Named page routes send `screen_view` on push, replace and pop; pass `screenNameExtractor` to name them your own way.
- **Pure Dart:** sessions follow `client.appBecameActive()` and `client.appWentToBackground()`, which the Flutter package calls for you.

## Events for games and apps

```dart
SimpleDataLogs.track('level_start', {'level': 3});
SimpleDataLogs.track('level_complete', {'level': 3, 'duration_s': 42, 'score': 1200});
SimpleDataLogs.track('purchase', {'sku': 'gems_100', 'price': 0.99, 'currency': 'USD'});
SimpleDataLogs.track('signup', {'plan': 'pro'});
```

## Privacy

- No identifiers are collected for you. `device_id` is only what you set; use an anonymous id you keep, never an email or advertising id.
- No IP address is stored: ingest keeps only a two-letter country code.
- The opt-out deletes everything not yet sent.
- Events are kept in the app's support folder (Flutter) or the folder you choose (Dart), never in shared storage.

## How it behaves

- **Batching.** Events go out in batches of 50, or after the first event of a partial batch has waited 10 s in release, 5 s in debug (configurable). Every request body is under 256 KB; bodies of 1 KB or more are gzipped (not on the web).
- **Crash-safe outbox.** Each event is appended to a journal as it is tracked.
  - Batches are sealed into files and deleted only after a `202`.
  - The next run resends anything left over, including a journal cut short by a crash.
  - A batch that fails to read three times in a row is renamed `*.unreadable` and skipped.
- **Bounded.** The outbox keeps at most 10,000 events, 10 MB or 500 batch files; past that, the oldest batches are dropped with a log line. More than 5,000 events waiting to be written are skipped, with one log line.
- **Retries.** Timeouts, network errors, `429`, `503` and any other non-`202` answer are retried with exponential backoff and full jitter, from 1 s up to 5 min, never sooner than 250 ms, and never sooner than `Retry-After` (seconds or an HTTP-date).
- **Bad key (`401`).** Sending pauses with one error log line; nothing is lost. The SDK re-probes with its smallest batch after 1 minute, then every 10 minutes, and on the next run. Only a `202` or `413` ends the pause.
- **Too large (`413`).** The batch is split in half and resent. A single event still too large is dropped with a log line.
- **`415`.** The batch is set aside as `*.unsupported` and never resent unchanged.
- **Fail open.** Nothing throws into your app. Problems are logged through `SdkLog` (`dart:developer`, name `simpledatalogs`); set `SdkLog.handler` to route them into your own logger.
- **Web.** Flutter web keeps the outbox in memory, and the browser sends its own User-Agent.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Links

- Docs: https://simpledatalogs.com/docs
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Security: [SECURITY.md](SECURITY.md)
- License: [MIT](LICENSE)
