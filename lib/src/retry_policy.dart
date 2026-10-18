import 'dart:math';

/// Exponential backoff with full jitter, from 1 s up to 5 min, that never retries sooner than Retry-After.
class RetryPolicy {
  /// The backoff ceiling after the first failure.
  final Duration initialDelay;

  /// The largest backoff ceiling (ingest API: 5 min).
  final Duration maximumDelay;

  /// The shortest wait, so a jitter draw near zero can never spin the send loop.
  final Duration minimumDelay;

  /// The longest Retry-After honored, so a broken header cannot stall sending for days.
  final Duration maximumRetryAfter;

  /// The first re-probe after a 401, soon enough to catch a brand-new key going live (~30 s).
  final Duration invalidKeyFirstProbeDelay;

  /// Every later re-probe while the key keeps answering 401 (ingest API: every ~10 min).
  final Duration invalidKeyProbeInterval;

  /// The ingest API defaults; tests shrink them.
  const RetryPolicy({
    this.initialDelay = const Duration(seconds: 1),
    this.maximumDelay = const Duration(minutes: 5),
    this.minimumDelay = const Duration(milliseconds: 250),
    this.maximumRetryAfter = const Duration(hours: 1),
    this.invalidKeyFirstProbeDelay = const Duration(minutes: 1),
    this.invalidKeyProbeInterval = const Duration(minutes: 10),
  });

  /// The jitter-free ceiling after this many consecutive failures: 1 s, 2 s, 4 s … 5 min.
  Duration backoffCeiling(int failureCount) {
    // Cap the exponent so the doubling can never overflow.
    final doublingCount = min(max(failureCount - 1, 0), 30);
    final ceilingMicroseconds = initialDelay.inMicroseconds * pow(2, doublingCount);

    return Duration(microseconds: min(maximumDelay.inMicroseconds, ceilingMicroseconds.toInt()));
  }

  /// The wait before the next attempt: a full-jitter backoff of at least 250 ms, but never less than Retry-After.
  Duration delay(int failureCount, {Duration? retryAfter, required double jitterFraction}) {
    // Full jitter picks uniformly between zero and the ceiling, then the floor applies.
    final clampedJitterFraction = jitterFraction.clamp(0.0, 1.0);
    final jitteredMicroseconds = (backoffCeiling(failureCount).inMicroseconds * clampedJitterFraction).round();
    final jitteredBackoff = Duration(microseconds: max(minimumDelay.inMicroseconds, jitteredMicroseconds));

    return _honoringRetryAfter(retryAfter, jitteredBackoff);
  }

  /// The wait before the next 401 re-probe, pushed later by a Retry-After from a probe that got 429 or 503.
  Duration invalidKeyProbeDelay(int probeCount, {Duration? retryAfter}) {
    final scheduledProbeDelay = probeCount == 0 ? invalidKeyFirstProbeDelay : invalidKeyProbeInterval;

    return _honoringRetryAfter(retryAfter, scheduledProbeDelay);
  }

  // Treats the server's Retry-After as a floor over the delay, within a sane bound.
  Duration _honoringRetryAfter(Duration? retryAfter, Duration delay) {
    if (retryAfter == null) {
      return delay;
    }

    final boundedRetryAfter = retryAfter > maximumRetryAfter ? maximumRetryAfter : retryAfter;
    return boundedRetryAfter > delay ? boundedRetryAfter : delay;
  }
}

/// Parses an HTTP Retry-After header, given as delay-seconds or an HTTP-date (RFC 9110).
class RetryAfterHeader {
  /// English month abbreviations, as HTTP-dates spell them.
  static const List<String> _monthNames = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

  /// The wait from `now`, or null when the header is missing or unreadable.
  static Duration? delay(String? headerValue, DateTime now) {
    // A missing or blank header carries no hint.
    final trimmedValue = headerValue?.trim() ?? '';
    if (trimmedValue.isEmpty) {
      return null;
    }

    // delay-seconds is a bare non-negative integer.
    if (RegExp(r'^[0-9]+$').hasMatch(trimmedValue)) {
      final delaySeconds = int.tryParse(trimmedValue);
      return delaySeconds == null ? null : Duration(seconds: delaySeconds);
    }

    // An HTTP-date in the past means retry now.
    final retryDate = parseHttpDate(trimmedValue);
    if (retryDate == null) {
      return null;
    }

    final waitDuration = retryDate.difference(now.toUtc());
    return waitDuration.isNegative ? Duration.zero : waitDuration;
  }

  /// Parses an IMF-fixdate, RFC 850 or asctime date, always in GMT; null when it reads as none of them.
  static DateTime? parseHttpDate(String dateText) {
    // asctime pads single-digit days with a second space, so collapse runs of spaces first.
    final dateParts = dateText.trim().split(RegExp(r'\s+'));

    // IMF-fixdate, "Sun, 06 Nov 1994 08:49:37 GMT".
    if (dateParts.length == 6 && dateParts[5] == 'GMT') {
      return _buildDate(year: dateParts[3], monthName: dateParts[2], day: dateParts[1], clock: dateParts[4]);
    }

    // RFC 850, "Sunday, 06-Nov-94 08:49:37 GMT", with a two-digit year.
    if (dateParts.length == 4 && dateParts[3] == 'GMT') {
      final dayMonthYear = dateParts[1].split('-');
      if (dayMonthYear.length != 3) {
        return null;
      }

      final twoDigitYear = int.tryParse(dayMonthYear[2]);
      if (twoDigitYear == null) {
        return null;
      }

      // Two-digit years more than 50 years ahead belong to the past century (RFC 9110).
      final fourDigitYear = twoDigitYear < 70 ? 2000 + twoDigitYear : 1900 + twoDigitYear;
      return _buildDate(year: '$fourDigitYear', monthName: dayMonthYear[1], day: dayMonthYear[0], clock: dateParts[2]);
    }

    // asctime, "Sun Nov  6 08:49:37 1994".
    if (dateParts.length == 5) {
      return _buildDate(year: dateParts[4], monthName: dateParts[1], day: dateParts[2], clock: dateParts[3]);
    }

    return null;
  }

  // Assembles a UTC date from its text parts, or null when any part does not read.
  static DateTime? _buildDate({required String year, required String monthName, required String day, required String clock}) {
    final monthIndex = _monthNames.indexOf(monthName.toLowerCase());
    final clockParts = clock.split(':');
    if (monthIndex < 0 || clockParts.length != 3) {
      return null;
    }

    // Every numeric part must be a plain number.
    final numericParts = [year, day, ...clockParts].map(int.tryParse).toList();
    if (numericParts.contains(null)) {
      return null;
    }

    return DateTime.utc(numericParts[0]!, monthIndex + 1, numericParts[1]!, numericParts[2]!, numericParts[3]!, numericParts[4]!);
  }
}
