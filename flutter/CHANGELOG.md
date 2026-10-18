# Changelog

All notable changes to the `simpledatalogs` and `simpledatalogs_flutter` packages. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the packages use [Semantic Versioning](https://semver.org/).

## [0.1.0] - Unreleased

The first public release.

### Added

- `SimpleDataLogs.configure`, `track`, `trackScreen`, `trackError`, `setDeviceId`, `setDefaultProperties`, `setEnabled`, `flush` and `close`, plus `SimpleDataLogsClient` for several keys in one process.
- A crash-safe outbox (`FileOutboxStorage` on the VM and Flutter, memory elsewhere) with batching, gzip, retries with jittered backoff, `Retry-After`, 401 pauses, 413 splitting and 415 set-asides.
- Bounded storage: at most 10,000 events, 10 MB or 500 batch files.
- Opt-in autocapture of launches, sessions and errors.
- `simpledatalogs_flutter`: a disk outbox in the app support folder, flushes when the app is hidden, error hooks, and `SimpleDataLogsNavigatorObserver` for screen views.
