import 'package:simpledatalogs/src/session_tracker.dart';
import 'package:test/test.dart';

void main() {
  final launchTime = DateTime.utc(2026, 10, 19, 12);
  var sessionNumber = 0;

  // Gives each new session a predictable id.
  String nextSessionId() {
    sessionNumber += 1;
    return 'session-$sessionNumber';
  }

  setUp(() => sessionNumber = 0);

  test('starts a session on the first activity', () {
    final tracker = SessionTracker();
    final changes = tracker.appBecameActive(launchTime, newSessionId: nextSessionId);

    expect(changes.single, isA<SessionStarted>().having((change) => change.sessionId, 'sessionId', 'session-1'));
    expect(tracker.session?.id, 'session-1');
  });

  test('resumes a session after less than 30 minutes away', () {
    final tracker = SessionTracker();
    tracker.appBecameActive(launchTime, newSessionId: nextSessionId);
    tracker.appWentToBackground(launchTime.add(const Duration(minutes: 5)));

    final changes = tracker.appBecameActive(launchTime.add(const Duration(minutes: 34)), newSessionId: nextSessionId);

    expect(changes, isEmpty);
    expect(tracker.session?.id, 'session-1');
    expect(tracker.session?.isInBackground, isFalse);
  });

  test('ends a session at its last activity after 30 minutes away, then starts a new one', () {
    final tracker = SessionTracker();
    tracker.appBecameActive(launchTime, newSessionId: nextSessionId);
    tracker.appWentToBackground(launchTime.add(const Duration(minutes: 10)));

    final changes = tracker.appBecameActive(launchTime.add(const Duration(minutes: 40)), newSessionId: nextSessionId);

    expect(changes.length, 2);
    expect(
      changes.first,
      isA<SessionEnded>()
          .having((change) => change.sessionId, 'sessionId', 'session-1')
          .having((change) => change.endedAt, 'endedAt', launchTime.add(const Duration(minutes: 10)))
          .having((change) => change.durationSeconds, 'durationSeconds', 600),
    );
    expect(changes.last, isA<SessionStarted>().having((change) => change.sessionId, 'sessionId', 'session-2'));
  });

  test('round-trips a saved session', () {
    final savedSession = TrackedSession(id: 'abc', startedAt: launchTime, lastActiveAt: launchTime.add(const Duration(seconds: 9)));
    final restoredSession = TrackedSession.fromJson(savedSession.toJson())!;

    expect(restoredSession.id, 'abc');
    expect(restoredSession.lastActiveAt, savedSession.lastActiveAt);
    expect(TrackedSession.fromJson({'id': 3}), isNull);
    expect(TrackedSession.fromJson('nonsense'), isNull);
  });
}
