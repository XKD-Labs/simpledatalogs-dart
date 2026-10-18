import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simpledatalogs/src/event_outbox.dart';
import 'package:simpledatalogs/src/simpledatalogs_client.dart';
import 'package:simpledatalogs/src/tracked_event.dart';
import 'package:test/test.dart';

import 'support/test_tuning.dart';

// A random string mixing ASCII, quotes, control characters and non-Latin text.
String randomText(Random random) {
  const alphabet = ['a', 'Z', '0', ' ', '"', '\\', '\n', '\r', '\t', '\u0000', '\u001f', 'é', '漢', '🙂', '{', '}', ','];
  final textLength = random.nextInt(24);

  return List.generate(textLength, (_) => alphabet[random.nextInt(alphabet.length)]).join();
}

// A random property value of any accepted or rejected type.
Object? randomPropertyValue(Random random) {
  return switch (random.nextInt(8)) {
    0 => randomText(random),
    1 => random.nextInt(1 << 31) - (1 << 30),
    2 => random.nextDouble() * 1e6,
    3 => random.nextBool(),
    4 => double.nan,
    5 => null,
    6 => [random.nextInt(9)],
    _ => double.negativeInfinity,
  };
}

void main() {
  // Encoding never breaks the one-event-per-line rule.
  test('random events always encode to one valid JSON line that round-trips', () {
    final random = Random(42);

    for (var caseIndex = 0; caseIndex < 500; caseIndex += 1) {
      final rawProperties = {
        for (var propertyIndex = 0; propertyIndex < random.nextInt(8); propertyIndex += 1) randomText(random): randomPropertyValue(random)
      };
      final eventName = 'e${randomText(random)}';

      final event = TrackedEvent.make(
        eventName: eventName,
        properties: sanitizeProperties(rawProperties),
        defaultProperties: const {},
        occurredAt: DateTime.utc(2026),
      );
      final eventLine = event.encodedLine();
      final decodedEvent = jsonDecode(eventLine) as Map<String, Object?>;

      expect(eventLine.contains('\n'), isFalse);
      expect(decodedEvent['event'], eventName);
      expect(decodedEvent['props'], event.properties);
      expect(
        (decodedEvent['props'] as Map)
            .values
            .every((propertyValue) => propertyValue is String || propertyValue is num || propertyValue is bool),
        isTrue,
      );
    }
  });

  // Delivery: whatever the server answers, each event is stored exactly once in the end.
  test('random answer sequences never lose or duplicate an event', () async {
    final random = Random(1234);

    for (var scenarioIndex = 0; scenarioIndex < 25; scenarioIndex += 1) {
      final acceptedEventIds = <String>[];
      final droppedLoneEventIds = <String>[];
      final answerStatuses = [202, 202, 202, 401, 413, 429, 500, 503, 200, 408];

      // A fake ingest that answers at random, and stores only what it answers 202.
      final mockClient = MockClient((request) async {
        final statusCode = answerStatuses[random.nextInt(answerStatuses.length)];
        final isGzipped = request.headers['Content-Encoding'] == 'gzip';
        final bodyText = utf8.decode(isGzipped ? gzip.decode(request.bodyBytes) : request.bodyBytes);
        final requestEventIds = bodyText
            .split('\n')
            .where((bodyLine) => bodyLine.isNotEmpty)
            .map((bodyLine) => (jsonDecode(bodyLine) as Map)['event_id'] as String)
            .toList();

        // A 202 stores the batch; a 413 on a lone event is the one answer that drops it.
        if (statusCode == 202) {
          acceptedEventIds.addAll(requestEventIds);
        } else if (statusCode == 413 && requestEventIds.length == 1) {
          droppedLoneEventIds.addAll(requestEventIds);
        }

        return http.Response('', statusCode, headers: {if (statusCode == 503) 'retry-after': '0'});
      });

      final client = SimpleDataLogsClient(
        ingestKey: 'sdl_pub_test',
        httpClient: mockClient,
        tuning: const PipelineTuning(retryPolicy: fastRetryPolicy, limits: OutboxLimits(maxBatchEventCount: 7)),
      );

      // Track a random number of events, flushing at random moments.
      final eventCount = random.nextInt(40) + 1;
      for (var eventIndex = 0; eventIndex < eventCount; eventIndex += 1) {
        client.track('event_$eventIndex', {'index': eventIndex});

        if (random.nextInt(5) == 0) {
          await client.flush();
        }
      }

      await flushUntilDrained(client, timeout: const Duration(seconds: 20));
      await client.close();

      // Every event was stored once or dropped as a lone 413, never both, never twice.
      final settledEventIds = {...acceptedEventIds, ...droppedLoneEventIds};
      expect(acceptedEventIds.toSet().length, acceptedEventIds.length, reason: 'scenario $scenarioIndex stored a duplicate');
      expect(acceptedEventIds.length + droppedLoneEventIds.length, eventCount, reason: 'scenario $scenarioIndex');
      expect(settledEventIds.length, eventCount, reason: 'scenario $scenarioIndex');
    }
  });
}
