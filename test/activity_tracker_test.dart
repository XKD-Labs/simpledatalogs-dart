import 'dart:io';

import 'package:simpledatalogs/io.dart';
import 'package:simpledatalogs/src/activity_tracker.dart';
import 'package:simpledatalogs/src/simpledatalogs_client.dart';
import 'package:test/test.dart';

import 'support/fake_ingest_server.dart';
import 'support/test_tuning.dart';

void main() {
  // The moment some milliseconds after a fixed start.
  DateTime at(int milliseconds) => DateTime.utc(2026, 10, 26).add(Duration(milliseconds: milliseconds));

  test('foreground time counts between stamps and background time is left out', () {
    final tracker = ActivityTracker(isActive: true, at: at(0));

    expect(tracker.stamp(at(30000)), {'app_state': 'active', 'engaged_ms': 30000});

    tracker.setActive(false, at(40000));
    expect(tracker.stamp(at(600000)), {'app_state': 'background'});

    // Back in front for 20 seconds after an hour away; a repeated notification changes nothing.
    tracker.setActive(true, at(3600000));
    tracker.setActive(true, at(3610000));
    expect(tracker.stamp(at(3620000)), {'app_state': 'active', 'engaged_ms': 20000});
  });

  test('a finished stretch counts once and the engaged time never passes a day', () {
    final tracker = ActivityTracker(isActive: false, at: at(0));

    tracker.setActive(true, at(100));
    tracker.setActive(false, at(145));
    tracker.setActive(true, at(200));
    expect(tracker.stamp(at(210)), {'app_state': 'active', 'engaged_ms': 55});
    expect(tracker.stamp(at(2 * 86400000)), {'app_state': 'active', 'engaged_ms': 86400000});
  });

  test('events tracked now carry the stamp once the app state is known; the caller wins', () async {
    final outboxDirectory = await Directory.systemTemp.createTemp('sdl-dart-activity-');
    final server = FakeIngestServer([]);
    await server.start();
    addTearDown(() async {
      await server.stop();
      await outboxDirectory.delete(recursive: true);
    });

    // A clock the test moves.
    var nowMilliseconds = 0;
    final client = SimpleDataLogsClient(
      ingestKey: 'sdl_pub_test',
      endpoint: server.endpoint,
      storage: FileOutboxStorage(outboxDirectory),
      tuning: PipelineTuning(retryPolicy: fastRetryPolicy, requestTimeout: const Duration(seconds: 5), now: () => at(nowMilliseconds)),
    );
    addTearDown(client.close);

    client.track('before_lifecycle');
    client.setAppActive(true);
    nowMilliseconds = 5000;
    client.track('opened');
    client.setAppActive(false);
    nowMilliseconds = 65000;
    client.track('synced');
    client.track('marked', {'app_state': 'active'});
    await flushUntilDrained(client);

    final sentProps = server.requests.expand((request) => request.events).map((event) => event['props'] ?? <String, Object?>{}).toList();
    expect(sentProps, [
      <String, Object?>{},
      {'app_state': 'active', 'engaged_ms': 5000},
      {'app_state': 'background'},
      {'app_state': 'active'},
    ]);
  });
}
