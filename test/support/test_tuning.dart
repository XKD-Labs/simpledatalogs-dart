import 'package:simpledatalogs/src/retry_policy.dart';
import 'package:simpledatalogs/src/simpledatalogs_client.dart';

/// Millisecond-scale retries, so tests never sleep for real seconds.
const RetryPolicy fastRetryPolicy = RetryPolicy(
  initialDelay: Duration(milliseconds: 5),
  maximumDelay: Duration(milliseconds: 40),
  minimumDelay: Duration(milliseconds: 1),
  maximumRetryAfter: Duration(seconds: 5),
  invalidKeyFirstProbeDelay: Duration(milliseconds: 60),
  invalidKeyProbeInterval: Duration(milliseconds: 120),
);

/// The defaults with fast retries.
const PipelineTuning fastTuning = PipelineTuning(retryPolicy: fastRetryPolicy, requestTimeout: Duration(seconds: 5));

/// Flushes until the client's outbox is empty, or fails after the timeout.
Future<void> flushUntilDrained(SimpleDataLogsClient client, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);

  // Each flush stops at a backoff, so keep going until nothing is left.
  while (DateTime.now().isBefore(deadline)) {
    await client.flush();
    if (await client.pendingEventCount() == 0) {
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  throw StateError('The outbox did not drain within $timeout');
}
