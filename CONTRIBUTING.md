# Contributing

Thanks for helping. Issues and pull requests are welcome at [XKD-Labs/simpledatalogs-dart](https://github.com/XKD-Labs/simpledatalogs-dart).

## Layout

- `/` is the pure Dart package `simpledatalogs` (`lib/`, `test/`, `example/`).
- `flutter/` is the companion package `simpledatalogs_flutter`. Its `pubspec_overrides.yaml` points it at the core in this repository.

## Test

You need either the Dart and Flutter SDKs, or Docker. With Docker, nothing is installed on your machine:

```sh
# Core: format, analyze and test
docker run --rm -v "$PWD":/w -w /w dart:3.9.4 sh -c 'dart pub get && dart format --output none --set-exit-if-changed . && dart analyze --fatal-infos && dart test'

# Core: check it still compiles for the web
docker run --rm -v "$PWD":/w -w /w dart:3.9.4 sh -c 'dart pub get && dart compile js -o /tmp/example.js tool/web_compile_check.dart'

# Flutter companion: analyze and test
docker run --rm -v "$PWD":/w -w /w/flutter ghcr.io/cirruslabs/flutter:3.35.6 sh -c 'flutter pub get && flutter analyze && flutter test'
```

With local SDKs, run the same commands without `docker run`: `dart test` at the root, `flutter test` in `flutter/`.

The tests start a real local HTTP server as a fake ingest endpoint, so they never touch the network.

## Style

- `dart format` with a 140-column page (set in `analysis_options.yaml`).
- Every public member has a one-line `///` doc; every private member and every step of a longer function has a one-line `//` comment.
- Self-describing names; booleans start with `is`, `has` or `should`.

## Releasing

Maintainers only, from their own machine (`dart pub login` once); nothing runs on GitHub.

1. Update `version` in `pubspec.yaml` (and `flutter/pubspec.yaml`), `lib/src/version.dart` and both changelogs.
2. Run the tests above, then publish the core first, since the Flutter package resolves it from pub.dev: `dart pub publish` at the root. Tag `vX.Y.Z` and push.
3. Then the Flutter package, without the local override: in `flutter/`, move `pubspec_overrides.yaml` aside, run `flutter pub get && flutter test && flutter pub publish`, put the file back, tag `flutter-vX.Y.Z` and push.
