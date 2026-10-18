import 'dart:io';

import 'package:simpledatalogs/io.dart';
import 'package:simpledatalogs/simpledatalogs.dart';
import 'package:test/test.dart';

import 'support/fake_ingest_server.dart';
import 'support/test_tuning.dart';

void main() {
  late FakeIngestServer server;
  late Directory outboxDirectory;

  setUp(() async {
    outboxDirectory = await Directory.systemTemp.createTemp('sdl-dart-');
  });

  tearDown(() async {
    await server.stop();
    await outboxDirectory.delete(recursive: true);
  });

  // Starts the scripted server and a client with a disk outbox pointed at it.
  Future<SimpleDataLogsClient> startClient(List<ScriptedAnswer> scriptedAnswers, {String ingestKey = 'sdl_pub_test'}) async {
    server = FakeIngestServer(scriptedAnswers);
    await server.start();

    final client = SimpleDataLogsClient(
      ingestKey: ingestKey,
      endpoint: server.endpoint,
      storage: FileOutboxStorage(outboxDirectory),
      tuning: fastTuning,
    );
    addTearDown(client.close);

    return client;
  }

  test('sends NDJSON with the ingest headers and empties the outbox on 202', () async {
    final client = await startClient([]);
    client.setDeviceId('device-1');
    client.track('level_start', {'level': 1});
    client.trackScreen('Menu');

    await flushUntilDrained(client);

    final receivedRequest = server.requests.single;
    expect(receivedRequest.headers['authorization'], 'Bearer sdl_pub_test');
    expect(receivedRequest.headers['content-type'], startsWith('application/x-ndjson'));
    expect(receivedRequest.headers['user-agent'], 'simpledatalogs-dart/0.1.0');
    expect(receivedRequest.events.map((event) => event['event']), ['level_start', 'screen_view']);
    expect(receivedRequest.events.last['props'], {'screen': 'Menu'});
    expect(receivedRequest.events.first['device_id'], 'device-1');
  });

  test('gzips large bodies', () async {
    final client = await startClient([]);

    for (var eventNumber = 0; eventNumber < 20; eventNumber += 1) {
      client.track('bulk', {'index': eventNumber, 'padding': 'x' * 100});
    }

    await flushUntilDrained(client);

    final receivedRequest = server.requests.single;
    expect(receivedRequest.headers['content-encoding'], 'gzip');
    expect(receivedRequest.events.length, 20);
    expect(receivedRequest.sentByteCount < receivedRequest.bodyText.length, isTrue);
  });

  test('retries a 503 after Retry-After with the same event_id and ts', () async {
    final client = await startClient([
      const ScriptedAnswer(503, headers: {'Retry-After': '1'}),
    ]);
    client.track('purchase', {'sku': 'gems_100'});

    final firstAttemptAt = DateTime.now();
    await flushUntilDrained(client);

    expect(server.requests.length, 2);
    expect(DateTime.now().difference(firstAttemptAt) >= const Duration(milliseconds: 900), isTrue);
    expect(server.requests[1].events.single['event_id'], server.requests[0].events.single['event_id']);
    expect(server.requests[1].events.single['ts'], server.requests[0].events.single['ts']);
  });

  test('retries 429, 500 and other non-202 answers', () async {
    final client = await startClient([
      const ScriptedAnswer(429),
      const ScriptedAnswer(500),
      const ScriptedAnswer(200),
      const ScriptedAnswer(408),
    ]);
    client.track('tutorial_step', {'step': 1});

    await flushUntilDrained(client);

    expect(server.requests.length, 5);
    expect(server.acceptedEventIds.length, 1);
  });

  test('pauses on 401, keeps the events, and re-probes until the key works', () async {
    final client = await startClient([const ScriptedAnswer(401), const ScriptedAnswer(401)]);
    client.track('signup');

    // The first answer pauses sending; nothing is lost.
    await client.flush();
    expect(server.requests.length, 1);
    expect(await client.pendingEventCount(), 1);

    // Probes follow on their own schedule until a 202.
    await server.waitForRequests(3);
    await flushUntilDrained(client);

    expect(server.acceptedEventIds.length, 1);
  });

  test('splits a batch answered 413 and delivers both halves', () async {
    final client = await startClient([const ScriptedAnswer(413)]);

    for (var eventNumber = 0; eventNumber < 6; eventNumber += 1) {
      client.track('level_complete', {'level': eventNumber});
    }

    await flushUntilDrained(client);

    expect(server.requests.map((receivedRequest) => receivedRequest.events.length), [6, 3, 3]);
    expect(server.acceptedEventIds.toSet().length, 6);
  });

  test('sets a batch answered 415 aside and sends the next one', () async {
    final client = await startClient([const ScriptedAnswer(415)]);
    client.track('first');
    await client.flush();
    client.track('second');

    await flushUntilDrained(client);

    final outboxFileNames = outboxDirectory.listSync().map((outboxFile) => outboxFile.uri.pathSegments.last);
    expect(outboxFileNames.where((fileName) => fileName.endsWith('.unsupported')).length, 1);
    expect(server.requests.last.events.single['event'], 'second');
  });

  test('keeps events when the server is unreachable and sends them on the next run', () async {
    server = FakeIngestServer();
    await server.start();
    final unreachableEndpoint = server.endpoint;
    await server.stop();

    // The first run cannot reach anyone.
    final offlineClient = SimpleDataLogsClient(
      ingestKey: 'sdl_pub_test',
      endpoint: unreachableEndpoint,
      storage: FileOutboxStorage(outboxDirectory),
      tuning: fastTuning,
    );
    offlineClient.track('offline_event');
    await offlineClient.flush();
    expect(await offlineClient.pendingEventCount(), 1);
    await offlineClient.close();

    // The next run, online, delivers it.
    final onlineClient = await startClient([]);
    await flushUntilDrained(onlineClient);

    expect(server.requests.single.events.single['event'], 'offline_event');
  });

  test('an opt-out deletes everything not yet sent', () async {
    final client = await startClient([
      const ScriptedAnswer(503, headers: {'Retry-After': '60'})
    ]);
    client.track('kept_until_opt_out');
    await client.flush();

    client.setEnabled(false);
    client.track('ignored');

    expect(await client.pendingEventCount(), 0);
    expect(outboxDirectory.listSync().where((outboxFile) => outboxFile.path.endsWith('.ndjson')), isEmpty);
  });

  test('autocapture sends app_launched and session_start with a session id', () async {
    server = FakeIngestServer();
    await server.start();

    final client = SimpleDataLogsClient(
      ingestKey: 'sdl_pub_test',
      endpoint: server.endpoint,
      storage: FileOutboxStorage(outboxDirectory),
      autocapture: const AutocaptureOptions(appLaunches: true, sessions: true),
      tuning: fastTuning,
    );
    addTearDown(client.close);
    client.track('level_start');

    await flushUntilDrained(client);

    final sentEvents = server.requests.expand((receivedRequest) => receivedRequest.events).toList();
    expect(sentEvents.map((event) => event['event']), ['session_start', 'app_launched', 'level_start']);
    expect(sentEvents.map((event) => event['session_id']).toSet().length, 1);
    expect(sentEvents[1]['props'], {'is_first_launch': true});
  });
}
