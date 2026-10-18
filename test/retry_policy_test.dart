import 'dart:math';

import 'package:simpledatalogs/src/retry_policy.dart';
import 'package:test/test.dart';

void main() {
  const retryPolicy = RetryPolicy();
  final now = DateTime.utc(2026, 10, 19, 12);

  // The backoff ceiling and its jitter.
  group('RetryPolicy', () {
    test('doubles the ceiling from 1 s up to 5 min', () {
      expect(retryPolicy.backoffCeiling(1), const Duration(seconds: 1));
      expect(retryPolicy.backoffCeiling(2), const Duration(seconds: 2));
      expect(retryPolicy.backoffCeiling(5), const Duration(seconds: 16));
      expect(retryPolicy.backoffCeiling(10), const Duration(minutes: 5));
      expect(retryPolicy.backoffCeiling(10000), const Duration(minutes: 5));
    });

    test('keeps every jittered delay between 250 ms and the ceiling', () {
      final random = Random(7);

      // Property-style: random failure counts and jitter draws stay in bounds.
      for (var drawIndex = 0; drawIndex < 2000; drawIndex += 1) {
        final failureCount = random.nextInt(40) + 1;
        final retryDelay = retryPolicy.delay(failureCount, jitterFraction: random.nextDouble());

        expect(retryDelay >= const Duration(milliseconds: 250), isTrue);
        expect(retryDelay <= retryPolicy.backoffCeiling(failureCount), isTrue);
      }
    });

    test('never retries sooner than Retry-After, capped at one hour', () {
      expect(retryPolicy.delay(1, retryAfter: const Duration(seconds: 30), jitterFraction: 0.5), const Duration(seconds: 30));
      expect(retryPolicy.delay(1, retryAfter: const Duration(days: 3), jitterFraction: 0.5), const Duration(hours: 1));
      expect(retryPolicy.delay(20, retryAfter: const Duration(seconds: 1), jitterFraction: 1), const Duration(minutes: 5));
    });

    test('re-probes a bad key after 1 min, then every 10 min, honoring Retry-After', () {
      expect(retryPolicy.invalidKeyProbeDelay(0), const Duration(minutes: 1));
      expect(retryPolicy.invalidKeyProbeDelay(1), const Duration(minutes: 10));
      expect(retryPolicy.invalidKeyProbeDelay(0, retryAfter: const Duration(minutes: 20)), const Duration(minutes: 20));
    });
  });

  // Retry-After in both RFC 9110 forms.
  group('RetryAfterHeader', () {
    test('reads delay-seconds', () {
      expect(RetryAfterHeader.delay('120', now), const Duration(seconds: 120));
      expect(RetryAfterHeader.delay(' 0 ', now), Duration.zero);
    });

    test('reads all three HTTP-date layouts', () {
      expect(RetryAfterHeader.delay('Mon, 19 Oct 2026 12:00:30 GMT', now), const Duration(seconds: 30));
      expect(RetryAfterHeader.delay('Monday, 19-Oct-26 12:01:00 GMT', now), const Duration(minutes: 1));
      expect(RetryAfterHeader.delay('Mon Oct 19 12:00:05 2026', now), const Duration(seconds: 5));
      expect(RetryAfterHeader.delay('Mon Oct  9 12:00:00 2026', now), Duration.zero);
    });

    test('treats a past date as now, and garbage or blanks as no hint', () {
      expect(RetryAfterHeader.delay('Sun, 06 Nov 1994 08:49:37 GMT', now), Duration.zero);
      expect(RetryAfterHeader.delay('soon', now), isNull);
      expect(RetryAfterHeader.delay('-5', now), isNull);
      expect(RetryAfterHeader.delay('', now), isNull);
      expect(RetryAfterHeader.delay(null, now), isNull);
      expect(RetryAfterHeader.delay('Mon, 19 Foo 2026 12:00:30 GMT', now), isNull);
    });
  });
}
