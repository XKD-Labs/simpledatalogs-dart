import 'dart:convert';
import 'dart:math';

import 'sdk_log.dart';

/// One tracked event, stamped at `track` time and sent as one NDJSON line.
class TrackedEvent {
  /// The event name, e.g. `level_complete`.
  final String eventName;

  /// The per-event UUID that makes retries safe to dedupe.
  final String eventId;

  /// When the host app called `track`, in UTC.
  final DateTime occurredAt;

  /// The anonymous device id, when the host set one.
  final String? deviceId;

  /// The session id, when autocapture's sessions are on.
  final String? sessionId;

  /// Default properties merged with the event's own properties.
  final Map<String, Object> properties;

  /// Builds an event from parts already validated.
  const TrackedEvent({
    required this.eventName,
    required this.eventId,
    required this.occurredAt,
    required this.properties,
    this.deviceId,
    this.sessionId,
  });

  /// Stamps a new event, letting the event's own properties win over the defaults.
  factory TrackedEvent.make({
    required String eventName,
    required Map<String, Object> properties,
    required Map<String, Object> defaultProperties,
    required DateTime occurredAt,
    String? deviceId,
    String? sessionId,
    String? eventId,
  }) {
    // The call site knows best, so its properties overwrite same-named defaults.
    final mergedProperties = <String, Object>{...defaultProperties, ...properties};

    return TrackedEvent(
      eventName: eventName,
      eventId: eventId ?? newEventId(),
      occurredAt: occurredAt.toUtc(),
      deviceId: deviceId,
      sessionId: sessionId,
      properties: mergedProperties,
    );
  }

  /// The wire object, with the ingest API field names.
  Map<String, Object> toJson() {
    return {
      'event': eventName,
      'event_id': eventId,
      'ts': formatTimestamp(occurredAt),
      if (deviceId != null) 'device_id': deviceId!,
      if (sessionId != null) 'session_id': sessionId!,
      'props': properties,
    };
  }

  /// Encodes the event as one compact JSON line with no trailing newline.
  String encodedLine() => jsonEncode(toJson());
}

/// Formats a time as ISO 8601 in UTC with millisecond precision, e.g. `2026-10-12T09:14:03.120Z`.
String formatTimestamp(DateTime moment) {
  final utcMoment = moment.toUtc();

  // Pad each field by hand, since toIso8601String would add microseconds on the VM.
  final datePart = '${_padded(utcMoment.year, 4)}-${_padded(utcMoment.month, 2)}-${_padded(utcMoment.day, 2)}';
  final timePart = '${_padded(utcMoment.hour, 2)}:${_padded(utcMoment.minute, 2)}:${_padded(utcMoment.second, 2)}';

  return '${datePart}T$timePart.${_padded(utcMoment.millisecond, 3)}Z';
}

// Left-pads a number with zeros to the given width.
String _padded(int number, int width) => number.toString().padLeft(width, '0');

/// The random source for event ids; secure when the platform has one.
final Random _eventIdRandom = _makeEventIdRandom();

// Prefers a cryptographic source, falling back where the platform has none.
Random _makeEventIdRandom() {
  try {
    return Random.secure();
  } on UnsupportedError {
    return Random();
  }
}

/// A new random UUID v4 in lowercase, e.g. `0b7e4c4a-…`.
String newEventId([Random? random]) {
  final randomSource = random ?? _eventIdRandom;
  final uuidBytes = List<int>.generate(16, (_) => randomSource.nextInt(256));

  // Set the version (4) and the RFC 4122 variant bits.
  uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x40;
  uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80;

  // Join the hex digits into the 8-4-4-4-12 groups.
  final hexDigits = uuidBytes.map((uuidByte) => uuidByte.toRadixString(16).padLeft(2, '0')).join();

  return '${hexDigits.substring(0, 8)}-${hexDigits.substring(8, 12)}-${hexDigits.substring(12, 16)}-'
      '${hexDigits.substring(16, 20)}-${hexDigits.substring(20)}';
}

/// Keeps only the values the ingest API accepts (strings, finite numbers, booleans), logging each dropped key.
Map<String, Object> sanitizeProperties(Map<String, Object?> properties) {
  final validProperties = <String, Object>{};

  for (final propertyEntry in properties.entries) {
    final propertyValue = propertyEntry.value;

    // Strings, integers and booleans pass through unchanged.
    if (propertyValue is String || propertyValue is int || propertyValue is bool) {
      validProperties[propertyEntry.key] = propertyValue!;
      continue;
    }

    // Doubles pass only when JSON can carry them.
    if (propertyValue is double && propertyValue.isFinite) {
      validProperties[propertyEntry.key] = propertyValue;
      continue;
    }

    // Everything else (null, NaN, lists, maps, objects) is logged so the host can fix its call site.
    SdkLog.warning('Dropped property ${propertyEntry.key}: only strings, finite numbers and booleans are sent');
  }

  return validProperties;
}
