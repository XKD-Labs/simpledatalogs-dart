import 'tracked_event.dart';

/// The events autocapture may send; all off unless you pass them to `configure`.
class AutocaptureOptions {
  /// `app_launched` once per `configure`, with `is_first_launch`.
  final bool appLaunches;

  /// `session_start`, `session_end` and a `session_id` on every event; a session ends after 30 minutes away.
  final bool sessions;

  /// Uncaught errors as `app_error` events; the Flutter companion wires them, plain Dart uses `trackError`.
  final bool errors;

  /// Picks each kind of autocapture.
  const AutocaptureOptions({this.appLaunches = false, this.sessions = false, this.errors = false});

  /// No autocapture: the default.
  static const AutocaptureOptions none = AutocaptureOptions();

  /// Launches, sessions and errors.
  static const AutocaptureOptions all = AutocaptureOptions(appLaunches: true, sessions: true, errors: true);

  /// True when nothing is captured automatically.
  bool get isEmpty => !appLaunches && !sessions && !errors;
}

/// One running session.
class TrackedSession {
  /// The session id put on every event.
  final String id;

  /// When the session began.
  final DateTime startedAt;

  /// The last moment the app was active, or when it went to the background.
  DateTime lastActiveAt;

  /// True while the app is in the background.
  bool isInBackground;

  /// Describes a session.
  TrackedSession({required this.id, required this.startedAt, required this.lastActiveAt, this.isInBackground = false});

  /// The saved form, so a relaunch within the timeout resumes the session.
  Map<String, Object> toJson() {
    return {
      'id': id,
      'started_at': startedAt.toUtc().millisecondsSinceEpoch,
      'last_active_at': lastActiveAt.toUtc().millisecondsSinceEpoch,
      'is_in_background': isInBackground,
    };
  }

  /// Reads a saved session, or null when the saved form does not read.
  static TrackedSession? fromJson(Object? savedSession) {
    if (savedSession is! Map) {
      return null;
    }

    final sessionId = savedSession['id'];
    final startedAtMilliseconds = savedSession['started_at'];
    final lastActiveAtMilliseconds = savedSession['last_active_at'];
    if (sessionId is! String || startedAtMilliseconds is! int || lastActiveAtMilliseconds is! int) {
      return null;
    }

    return TrackedSession(
      id: sessionId,
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAtMilliseconds, isUtc: true),
      lastActiveAt: DateTime.fromMillisecondsSinceEpoch(lastActiveAtMilliseconds, isUtc: true),
      isInBackground: savedSession['is_in_background'] == true,
    );
  }
}

/// What one lifecycle moment produced, in order.
sealed class SessionChange {
  /// Builds a change.
  const SessionChange();
}

/// A session began.
class SessionStarted extends SessionChange {
  /// The new session's id.
  final String sessionId;

  /// When it began.
  final DateTime startedAt;

  /// Describes a start.
  const SessionStarted(this.sessionId, this.startedAt);
}

/// A session ended at its last activity.
class SessionEnded extends SessionChange {
  /// The ended session's id.
  final String sessionId;

  /// Its last activity, which is when it ended.
  final DateTime endedAt;

  /// Its length in whole seconds.
  final int durationSeconds;

  /// Describes an end.
  const SessionEnded(this.sessionId, this.endedAt, this.durationSeconds);
}

/// Starts, resumes and ends sessions from app activity; pure, so tests drive it with any clock.
class SessionTracker {
  /// Time away that ends a session, as in Firebase and most app analytics.
  static const Duration timeout = Duration(minutes: 30);

  /// The current session, if any.
  TrackedSession? session;

  /// Starts with a saved session, or none.
  SessionTracker({this.session});

  /// The app became active: ends a session idle for the whole timeout, then starts one or resumes the current one.
  List<SessionChange> appBecameActive(DateTime now, {String Function()? newSessionId}) {
    final changes = <SessionChange>[];
    final currentSession = session;

    // A session away for the whole timeout ends where its activity stopped.
    if (currentSession != null && now.difference(currentSession.lastActiveAt) >= timeout) {
      final activeDuration = currentSession.lastActiveAt.difference(currentSession.startedAt);
      final durationSeconds = (activeDuration.inMilliseconds / 1000).round();

      changes.add(SessionEnded(currentSession.id, currentSession.lastActiveAt, durationSeconds < 0 ? 0 : durationSeconds));
      session = null;
    }

    // No session: start one; otherwise resume it.
    final resumedSession = session;
    if (resumedSession == null) {
      final startedSession = TrackedSession(id: (newSessionId ?? newEventId)(), startedAt: now, lastActiveAt: now);
      session = startedSession;
      changes.add(SessionStarted(startedSession.id, now));
    } else {
      resumedSession
        ..lastActiveAt = now
        ..isInBackground = false;
    }

    return changes;
  }

  /// The app went to the background: remembers when, so the next activity can decide whether the session ended.
  void appWentToBackground(DateTime now) {
    session
      ?..lastActiveAt = now
      ..isInBackground = true;
  }
}
