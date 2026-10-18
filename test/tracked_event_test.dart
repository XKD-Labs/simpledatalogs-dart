import 'dart:convert';

import 'package:simpledatalogs/src/tracked_event.dart';
import 'package:test/test.dart';

void main() {
  // The wire line and its fields.
  group('TrackedEvent', () {
    test('encodes the ingest API field names on one line', () {
      final event = TrackedEvent.make(
        eventName: 'level_complete',
        properties: {'level': 3, 'note': 'line one\nline "two"'},
        defaultProperties: {'app_version': '1.0.0'},
        deviceId: 'device-1',
        sessionId: 'session-1',
        occurredAt: DateTime.utc(2026, 10, 12, 9, 14, 3, 120, 456),
        eventId: 'fixed-id',
      );

      final eventLine = event.encodedLine();
      final decodedEvent = jsonDecode(eventLine) as Map<String, Object?>;

      expect(eventLine.contains('\n'), isFalse);
      expect(decodedEvent['event'], 'level_complete');
      expect(decodedEvent['event_id'], 'fixed-id');
      expect(decodedEvent['ts'], '2026-10-12T09:14:03.120Z');
      expect(decodedEvent['device_id'], 'device-1');
      expect(decodedEvent['session_id'], 'session-1');
      expect(decodedEvent['props'], {'app_version': '1.0.0', 'level': 3, 'note': 'line one\nline "two"'});
    });

    test('leaves out device_id and session_id when unset, and keeps an empty props', () {
      final event = TrackedEvent.make(eventName: 'ping', properties: {}, defaultProperties: {}, occurredAt: DateTime.utc(2026));
      final decodedEvent = jsonDecode(event.encodedLine()) as Map<String, Object?>;

      expect(decodedEvent.containsKey('device_id'), isFalse);
      expect(decodedEvent.containsKey('session_id'), isFalse);
      expect(decodedEvent['props'], <String, Object?>{});
    });

    test('lets the event props win over the defaults', () {
      final event = TrackedEvent.make(
        eventName: 'purchase',
        properties: {'currency': 'EUR'},
        defaultProperties: {'currency': 'USD', 'platform': 'android'},
        occurredAt: DateTime.utc(2026),
      );

      expect(event.properties, {'currency': 'EUR', 'platform': 'android'});
    });

    test('converts a local time to UTC', () {
      final localMoment = DateTime(2026, 1, 2, 3, 4, 5, 6);

      expect(formatTimestamp(localMoment), formatTimestamp(localMoment.toUtc()));
      expect(formatTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5, 6)), '2026-01-02T03:04:05.006Z');
    });
  });

  // Event ids.
  group('newEventId', () {
    test('is a lowercase UUID v4 and unique', () {
      final uuidPattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
      final eventIds = List.generate(1000, (_) => newEventId());

      expect(eventIds.every(uuidPattern.hasMatch), isTrue);
      expect(eventIds.toSet().length, eventIds.length);
    });
  });

  // Property validation.
  group('sanitizeProperties', () {
    test('keeps strings, integers, finite doubles and booleans', () {
      final validProperties = sanitizeProperties({'name': 'a', 'count': 2, 'ratio': 0.5, 'is_pro': true});

      expect(validProperties, {'name': 'a', 'count': 2, 'ratio': 0.5, 'is_pro': true});
    });

    test('drops NaN, infinity, null, lists, maps and objects', () {
      final validProperties = sanitizeProperties({
        'nan': double.nan,
        'infinity': double.infinity,
        'missing': null,
        'list': [1, 2],
        'map': {'a': 1},
        'object': Object(),
        'kept': 'yes',
      });

      expect(validProperties, {'kept': 'yes'});
    });
  });
}
