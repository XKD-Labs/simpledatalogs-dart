import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'activity_tracker.dart';
import 'event_outbox.dart';
import 'ingest_client.dart';
import 'outbox_storage.dart';
import 'retry_policy.dart';
import 'sdk_log.dart';
import 'session_tracker.dart';
import 'tracked_event.dart';
import 'version.dart';

/// How long a partial batch waits: 5 s in debug and profile builds, so new events show within seconds; 10 s in release.
const Duration defaultBatchInterval = bool.fromEnvironment('dart.vm.product') ? Duration(seconds: 10) : Duration(seconds: 5);

/// Tunables tests shrink; every default follows the ingest API.
class PipelineTuning {
  /// Batch and total size limits.
  final OutboxLimits limits;

  /// Backoff and Retry-After rules.
  final RetryPolicy retryPolicy;

  /// How long one request may take.
  final Duration requestTimeout;

  /// The clock every stamp and timer reads.
  final DateTime Function() now;

  /// Returns a number in [0, 1) for the backoff jitter.
  final double Function() jitter;

  /// The defaults, with the real clock and a real random source.
  const PipelineTuning({
    this.limits = const OutboxLimits(),
    this.retryPolicy = const RetryPolicy(),
    this.requestTimeout = const Duration(seconds: 30),
    this.now = _utcNow,
    this.jitter = _randomJitter,
  });
}

// The real clock, in UTC.
DateTime _utcNow() => DateTime.now().toUtc();

/// The random source for backoff jitter.
final Random _jitterRandom = Random();

// A real jitter draw.
double _randomJitter() => _jitterRandom.nextDouble();

/// One sender for one ingest key: stamps events, keeps them in the outbox, and sends them in batches.
///
/// Most apps use the static `SimpleDataLogs` facade; servers and tests may create clients directly.
class SimpleDataLogsClient {
  /// The most track calls waiting for the outbox before new ones are skipped.
  static const int maxPendingTrackCount = 5000;

  /// The most `app_error` events per distinct message in one run.
  static const int maxErrorsPerMessage = 5;

  /// The most `app_error` events in one run.
  static const int maxErrorsPerRun = 50;

  /// Seal and send a partial batch this long after its first event (10 s in release, 5 s otherwise; servers ~5 s).
  final Duration batchInterval;

  /// What autocapture sends.
  final AutocaptureOptions autocapture;

  /// The outbox every event passes through.
  final EventOutbox _outbox;

  /// Sends batches and classifies answers.
  final IngestClient _ingestClient;

  /// Tunables and the injected clock.
  final PipelineTuning _tuning;

  /// True when this client created its HTTP client and so must close it.
  final bool _ownsHttpClient;

  /// Sessions, when autocapture's sessions are on.
  final SessionTracker _sessionTracker = SessionTracker();

  /// The tail of the serial operation chain; every outbox change runs in order behind it.
  Future<void> _operationChainTail = Future.value();

  /// Settles once the outbox is recovered and autocapture has started.
  late final Future<void> _ready;

  /// The running send loop, when one is running.
  Future<void>? _sendLoop;

  /// The wake-up for the next batch seal or retry.
  Timer? _wakeTimer;

  /// The zone this client was created in; every internal future and timer runs there, whatever zone the caller is in.
  final Zone _clientZone = Zone.current;

  /// False after an opt-out: events are ignored and the outbox is deleted.
  bool _isEnabled;

  /// True once `close` ran.
  bool _isClosed = false;

  /// The anonymous device id attached to every event.
  String? _deviceId;

  /// Properties merged into every event's props.
  Map<String, Object> _defaultProperties = {};

  /// The app's foreground time between events, once the Flutter companion reports the app's state.
  ActivityTracker? _activityTracker;

  /// Track calls queued and not yet journaled.
  int _pendingTrackCount = 0;

  /// True once the pending-track cap was logged, so a hot loop logs it once.
  bool _hasLoggedPendingTrackCap = false;

  /// Consecutive failed sends, for the backoff.
  int _failureCount = 0;

  /// No send starts before this moment.
  DateTime? _nextAttemptAt;

  /// True while a 401 holds sending until a probe succeeds.
  bool _isPausedForInvalidKey = false;

  /// 401 re-probes sent during the current pause.
  int _invalidKeyProbeCount = 0;

  /// `app_error` events sent this run, per message and in total.
  final Map<String, int> _errorCountsByMessage = {};

  /// Starts a client; the outbox is recovered in the background, and nothing here blocks or throws.
  SimpleDataLogsClient({
    required String ingestKey,
    Uri? endpoint,
    OutboxStorage? storage,
    this.autocapture = AutocaptureOptions.none,
    this.batchInterval = defaultBatchInterval,
    bool isEnabled = true,
    String? deviceId,
    Map<String, Object?> defaultProperties = const {},
    http.Client? httpClient,
    PipelineTuning tuning = const PipelineTuning(),
  })  : _tuning = tuning,
        _isEnabled = isEnabled,
        _deviceId = deviceId,
        _defaultProperties = sanitizeProperties(defaultProperties),
        _ownsHttpClient = httpClient == null,
        _outbox = EventOutbox(storage ?? MemoryOutboxStorage(), limits: tuning.limits),
        _ingestClient = IngestClient(
          ingestUrl: IngestClient.ingestUrlFor(endpoint ?? defaultEndpoint),
          ingestKey: ingestKey.trim(),
          httpClient: httpClient ?? http.Client(),
          requestTimeout: tuning.requestTimeout,
        ) {
    // An empty key can never work, so say so once at setup.
    if (ingestKey.trim().isEmpty) {
      SdkLog.error('SimpleDataLogs was given an empty ingest key; ingest will answer 401');
    }

    _ready = _enqueue(_startUp);
  }

  /// This SDK's version.
  static String get version => sdkVersion;

  /// True while collection is on.
  bool get isEnabled => _isEnabled;

  /// Events in the outbox now, journal and sealed batches together; for diagnostics and tests.
  Future<int> pendingEventCount() async => await _enqueue(() async => _outbox.totalEventCount) ?? 0;

  /// Records one event; it returns at once and never throws.
  void track(String eventName, [Map<String, Object?> properties = const {}]) {
    final occurredAt = _tuning.now();

    // An event happening now says whether someone was using the app; the caller's own props win.
    final activityProperties = _activityTracker?.stamp(occurredAt) ?? const {};
    _trackAt(eventName, {...activityProperties, ...properties}, occurredAt);
  }

  /// Records a screen view (`screen_view` with a `screen` prop).
  void trackScreen(String screenName, [Map<String, Object?> properties = const {}]) {
    track('screen_view', {...properties, 'screen': screenName});
  }

  /// Records an error as `app_error` (`exception_type`, `message`, `stack`), at most 5 per message and 50 per run.
  void trackError(Object error, [StackTrace? stackTrace, Map<String, Object?> properties = const {}]) {
    try {
      final errorMessage = _truncated(error.toString(), 1000);

      // A crash loop must not flood the outbox.
      final messageCount = _errorCountsByMessage[errorMessage] ?? 0;
      final runCount = _errorCountsByMessage.values.fold(0, (sum, count) => sum + count);
      if (messageCount >= maxErrorsPerMessage || runCount >= maxErrorsPerRun) {
        return;
      }

      _errorCountsByMessage[errorMessage] = messageCount + 1;

      track('app_error', {
        ...properties,
        'exception_type': error.runtimeType.toString(),
        'message': errorMessage,
        if (stackTrace != null) 'stack': _truncated(stackTrace.toString(), 4000),
      });
    } catch (trackError) {
      SdkLog.warning('Could not record an error: $trackError');
    }
  }

  /// Sets the anonymous device id attached to every later event, or clears it with null.
  void setDeviceId(String? deviceId) {
    _deviceId = deviceId;
  }

  /// Replaces the properties merged into every later event, e.g. app_version or platform.
  void setDefaultProperties(Map<String, Object?> properties) {
    _defaultProperties = sanitizeProperties(properties);
  }

  /// Turns collection on or off; turning it off also deletes every event not yet delivered.
  void setEnabled(bool isEnabled) {
    if (_isEnabled == isEnabled) {
      return;
    }

    _isEnabled = isEnabled;

    // An opt-out stops the timer and wipes the outbox; an opt-in just resumes.
    if (!isEnabled) {
      _wakeTimer?.cancel();
      _enqueue(_outbox.deleteEverything);
    } else {
      _enqueue(() async => _scheduleWake());
    }
  }

  /// Seals and sends everything tracked so far; completes when that attempt ends, keeping anything undelivered.
  Future<void> flush() async {
    try {
      await _ready;
      if (!_isEnabled || _isClosed) {
        return;
      }

      // Seal everything journaled so far, whatever the batch timer says.
      await _enqueue(() => _outbox.sealJournal(_tuning.now()));

      // Let a running loop finish, then run one more pass for what it may have missed.
      await _sendLoop;
      await _runSendLoop();
    } catch (flushError) {
      SdkLog.warning('Flush failed: $flushError');
    }
  }

  /// The app came to the front or left it; the first call turns on `app_state` and `engaged_ms`; the Flutter companion calls this.
  void setAppActive(bool isActive) {
    final now = _tuning.now();
    final runningTracker = _activityTracker;

    if (runningTracker == null) {
      _activityTracker = ActivityTracker(isActive: isActive, at: now);
    } else {
      runningTracker.setActive(isActive, now);
    }
  }

  /// Tells sessions the app is in the foreground; the Flutter companion calls this.
  void appBecameActive() {
    final becameActiveAt = _tuning.now();

    _enqueue(() async {
      if (autocapture.sessions) {
        await _applySessionChanges(_sessionTracker.appBecameActive(becameActiveAt));
      }
    });
  }

  /// Tells sessions the app went to the background, and flushes; the Flutter companion calls this.
  Future<void> appWentToBackground() async {
    final wentToBackgroundAt = _tuning.now();

    await _enqueue(() async {
      if (autocapture.sessions) {
        _sessionTracker.appWentToBackground(wentToBackgroundAt);
        await _saveSession();
      }
    });

    await flush();
  }

  /// Stops timers and closes the HTTP client; undelivered events stay in the outbox for the next run.
  Future<void> close() async {
    _isClosed = true;
    _wakeTimer?.cancel();

    // Let queued writes and a running send finish.
    await _operationChainTail;
    await _sendLoop;

    if (_ownsHttpClient) {
      _ingestClient.httpClient.close();
    }
  }

  // Stamps event_id and ts now, then journals the event in call order.
  void _trackAt(String eventName, Map<String, Object?> properties, DateTime occurredAt, {String? fixedSessionId}) {
    try {
      // An empty name cannot become an event.
      if (eventName.isEmpty) {
        SdkLog.error('track was called with an empty event name; event dropped');
        return;
      }

      if (!_isEnabled || _isClosed) {
        return;
      }

      // A host loop faster than the disk skips events instead of growing memory.
      if (_pendingTrackCount >= maxPendingTrackCount) {
        if (!_hasLoggedPendingTrackCap) {
          _hasLoggedPendingTrackCap = true;
          SdkLog.warning('More than $maxPendingTrackCount events wait for the outbox; new events are skipped until it catches up');
        }

        return;
      }

      // The id and time are fixed here, so every retry carries the same ones.
      final stampedEvent = TrackedEvent.make(
        eventName: eventName,
        properties: sanitizeProperties(properties),
        defaultProperties: _defaultProperties,
        deviceId: _deviceId,
        occurredAt: occurredAt,
      );

      _pendingTrackCount += 1;
      _enqueue(() async {
        _pendingTrackCount -= 1;
        await _journal(stampedEvent, fixedSessionId: fixedSessionId);
      });
    } catch (trackError) {
      SdkLog.warning('Could not record $eventName: $trackError');
    }
  }

  // Writes one event to the journal, sealing around it as the batch limits require.
  Future<void> _journal(TrackedEvent stampedEvent, {String? fixedSessionId}) async {
    if (!_isEnabled) {
      return;
    }

    // The session is attached in order behind earlier lifecycle changes.
    final sessionId = fixedSessionId ?? _sessionTracker.session?.id;
    final eventLine = TrackedEvent(
      eventName: stampedEvent.eventName,
      eventId: stampedEvent.eventId,
      occurredAt: stampedEvent.occurredAt,
      deviceId: stampedEvent.deviceId,
      sessionId: sessionId,
      properties: stampedEvent.properties,
    ).encodedLine();

    // Seal first when this line would overfill a request, then append.
    final now = _tuning.now();
    if (_outbox.wouldJournalOverflow(eventLine)) {
      await _outbox.sealJournal(now);
    }

    await _outbox.appendToJournal(eventLine, now);

    // A full batch goes at once; otherwise the batch timer takes it.
    if (_outbox.isJournalFull) {
      await _outbox.sealJournal(now);
      _kickSendLoop();
    } else {
      _scheduleWake();
    }
  }

  // Recovers the outbox, then starts autocapture.
  Future<void> _startUp() async {
    final now = _tuning.now();

    // A user who opted out before launch never sends a byte; leftovers are deleted.
    if (!_isEnabled) {
      await _outbox.deleteEverything();
      return;
    }

    await _outbox.recoverAfterLaunch(now);

    // Sessions resume within the timeout, or end and start anew.
    if (autocapture.sessions) {
      _sessionTracker.session = TrackedSession.fromJson(await _readJson(_sessionEntryName));
      await _applySessionChanges(_sessionTracker.appBecameActive(now));
    }

    // One launch event per run, marking the very first.
    if (autocapture.appLaunches) {
      final isFirstLaunch = await _outbox.storage.read(_firstLaunchMarkerName) == null;
      if (isFirstLaunch) {
        await _outbox.storage.write(_firstLaunchMarkerName, formatTimestamp(now));
      }

      final launchEvent = TrackedEvent.make(
        eventName: 'app_launched',
        properties: {'is_first_launch': isFirstLaunch},
        defaultProperties: _defaultProperties,
        deviceId: _deviceId,
        occurredAt: now,
      );
      await _journal(launchEvent);
    }

    // Send what earlier runs left behind.
    _kickSendLoop();
  }

  /// The entry holding the current session.
  static const String _sessionEntryName = 'session.json';

  /// The entry whose presence means this is not the first launch.
  static const String _firstLaunchMarkerName = 'first-launch.marker';

  // Sends session_end and session_start for each change, each with its own time and session id.
  Future<void> _applySessionChanges(List<SessionChange> sessionChanges) async {
    for (final sessionChange in sessionChanges) {
      switch (sessionChange) {
        case SessionEnded(:final sessionId, :final endedAt, :final durationSeconds):
          final endEvent = TrackedEvent.make(
            eventName: 'session_end',
            properties: {'duration_s': durationSeconds},
            defaultProperties: _defaultProperties,
            deviceId: _deviceId,
            occurredAt: endedAt,
          );
          await _journal(endEvent, fixedSessionId: sessionId);

        case SessionStarted(:final sessionId, :final startedAt):
          final startEvent = TrackedEvent.make(
            eventName: 'session_start',
            properties: const {},
            defaultProperties: _defaultProperties,
            deviceId: _deviceId,
            occurredAt: startedAt,
          );
          await _journal(startEvent, fixedSessionId: sessionId);
      }
    }

    await _saveSession();
  }

  // Saves the current session, so a relaunch within the timeout resumes it.
  Future<void> _saveSession() async {
    final currentSession = _sessionTracker.session;

    if (currentSession == null) {
      await _outbox.storage.delete(_sessionEntryName);
    } else {
      await _outbox.storage.write(_sessionEntryName, jsonEncode(currentSession.toJson()));
    }
  }

  // Reads one JSON entry, or null when it is missing or broken.
  Future<Object?> _readJson(String entryName) async {
    try {
      final entryText = await _outbox.storage.read(entryName);
      return entryText == null ? null : jsonDecode(entryText);
    } catch (_) {
      return null;
    }
  }

  // Starts the send loop unless one is running.
  void _kickSendLoop() {
    if (_sendLoop == null) {
      unawaited(_runSendLoop());
    }
  }

  // Sends eligible batches one at a time until none is left or a backoff holds sending.
  Future<void> _runSendLoop() {
    final runningLoop = _sendLoop;
    if (runningLoop != null) {
      return runningLoop;
    }

    final newLoop = _clientZone.run(_sendEligibleBatches).whenComplete(() {
      _sendLoop = null;
      _enqueue(() async => _scheduleWake());
    });

    _sendLoop = newLoop;
    return newLoop;
  }

  // The send loop body: pick a batch inside the chain, send it outside, apply the answer inside.
  Future<void> _sendEligibleBatches() async {
    while (_isEnabled && !_isClosed) {
      final pickedBatch = await _enqueue(_pickBatchToSend);
      if (pickedBatch == null) {
        return;
      }

      final outcome = await _ingestClient.send(pickedBatch.batchText);
      await _enqueue(() => _applyOutcome(pickedBatch.batch, pickedBatch.batchText, outcome));
    }
  }

  // The batch to send now with its text, or null when nothing is due.
  Future<({SealedBatch batch, String batchText})?> _pickBatchToSend() async {
    final now = _tuning.now();

    // A backoff or a 401 pause holds every send until its moment.
    final nextAttemptAt = _nextAttemptAt;
    if (nextAttemptAt != null && now.isBefore(nextAttemptAt)) {
      return null;
    }

    // Skip unreadable batches until one reads or none is left.
    while (true) {
      final candidateBatch = _isPausedForInvalidKey ? _outbox.smallestSealedBatch : _outbox.oldestSealedBatch;
      if (candidateBatch == null) {
        return null;
      }

      final batchText = await _outbox.readBatch(candidateBatch);
      if (batchText != null) {
        return (batch: candidateBatch, batchText: batchText);
      }

      // A batch still indexed after a failed read is retried on the next wake, not spun on now.
      if (_outbox.sealedBatches.contains(candidateBatch)) {
        _nextAttemptAt = now.add(_tuning.retryPolicy.minimumDelay);
        return null;
      }
    }
  }

  // Applies one ingest answer to the outbox and the retry state.
  Future<void> _applyOutcome(SealedBatch batch, String batchText, IngestOutcome outcome) async {
    final now = _tuning.now();
    final isBatchStillHeld = _outbox.sealedBatches.contains(batch);

    switch (outcome) {
      // Stored: delete it, clear the backoff, and end any 401 pause.
      case IngestAccepted():
        if (isBatchStillHeld) {
          await _outbox.deleteBatch(batch);
        }

        if (_isPausedForInvalidKey) {
          SdkLog.warning('The ingest key works again; sending resumed');
        }

        _clearBackoff();

      // A bad key pauses sending and re-probes slowly; nothing is lost.
      case IngestInvalidKey():
        if (!_isPausedForInvalidKey) {
          SdkLog.error('Ingest answered 401 invalid_key: check the key; events are kept and sending is paused');
        }

        _isPausedForInvalidKey = true;
        _nextAttemptAt = now.add(_tuning.retryPolicy.invalidKeyProbeDelay(_invalidKeyProbeCount));
        _invalidKeyProbeCount += 1;

      // Too large: split it and resend at once; this also proves the key works.
      case IngestPayloadTooLarge():
        if (isBatchStillHeld) {
          await _outbox.splitBatch(batch, batchText);
        }

        _clearBackoff();

      // Never resendable unchanged: set it aside and move on.
      case IngestUnsupported():
        SdkLog.error('Ingest answered 415 for ${batch.name}; it is set aside and never resent');
        if (isBatchStillHeld) {
          await _outbox.setAsideUnsupported(batch);
        }

      // Unknown whether stored: keep it and back off, never sooner than Retry-After.
      case IngestRetryable(:final retryAfter, :final reason):
        if (_isPausedForInvalidKey) {
          _nextAttemptAt = now.add(_tuning.retryPolicy.invalidKeyProbeDelay(_invalidKeyProbeCount, retryAfter: retryAfter));
        } else {
          _failureCount += 1;
          final retryDelay = _tuning.retryPolicy.delay(_failureCount, retryAfter: retryAfter, jitterFraction: _tuning.jitter());
          _nextAttemptAt = now.add(retryDelay);
          SdkLog.debug('Send failed ($reason); retrying in ${retryDelay.inMilliseconds} ms');
        }
    }
  }

  // Resets every backoff and pause after a send that proved the key and the server work.
  void _clearBackoff() {
    _failureCount = 0;
    _nextAttemptAt = null;
    _isPausedForInvalidKey = false;
    _invalidKeyProbeCount = 0;
  }

  // Arms one timer for the next batch seal or retry, whichever comes first.
  void _scheduleWake() {
    _wakeTimer?.cancel();
    if (!_isEnabled || _isClosed) {
      return;
    }

    final now = _tuning.now();
    final wakeMoments = <DateTime>[];
    final nextAttemptAt = _nextAttemptAt;

    // A partial batch seals once the interval passes, but not before a backoff ends.
    final journalStartedAt = _outbox.journalStartedAt;
    if (journalStartedAt != null) {
      final sealAt = journalStartedAt.add(batchInterval);
      final isHeldLonger = nextAttemptAt != null && nextAttemptAt.isAfter(sealAt);
      wakeMoments.add(isHeldLonger ? nextAttemptAt : sealAt);
    }

    // Sealed batches go as soon as the backoff allows.
    if (_outbox.sealedBatches.isNotEmpty) {
      wakeMoments.add(nextAttemptAt ?? now);
    }

    if (wakeMoments.isEmpty) {
      return;
    }

    // Wake at the earliest moment, never in the past.
    final earliestWake = wakeMoments.reduce((earliest, moment) => moment.isBefore(earliest) ? moment : earliest);
    final wakeDelay = earliestWake.difference(now);

    _wakeTimer = Timer(wakeDelay.isNegative ? Duration.zero : wakeDelay, _handleWake);
  }

  // The timer fired: seal a due partial batch, then send.
  void _handleWake() {
    _enqueue(() async {
      final now = _tuning.now();
      final journalStartedAt = _outbox.journalStartedAt;
      final nextAttemptAt = _nextAttemptAt;
      final isHoldingSends = nextAttemptAt != null && now.isBefore(nextAttemptAt);

      // While a backoff holds sending, the timer seals nothing, so offline days never leave a file per event.
      final isBatchDue = journalStartedAt != null && !now.isBefore(journalStartedAt.add(batchInterval));
      if (isBatchDue && !isHoldingSends) {
        await _outbox.sealJournal(now);
      }
    });

    _kickSendLoop();
  }

  // Runs one operation after every earlier one, logging instead of throwing.
  Future<T?> _enqueue<T>(Future<T> Function() operation) {
    final operationResult = Completer<T?>();

    // Chain in the client's own zone, so a caller's test or guarded zone never holds the work back.
    _clientZone.run(() {
      _operationChainTail = _operationChainTail.then((_) async {
        try {
          operationResult.complete(await operation());
        } catch (operationError) {
          SdkLog.warning('Outbox operation failed: $operationError');
          operationResult.complete(null);
        }
      });
    });

    return operationResult.future;
  }

  // Shortens long text, so one huge message cannot fill a batch.
  static String _truncated(String text, int maxLength) {
    return text.length <= maxLength ? text : text.substring(0, maxLength);
  }
}
