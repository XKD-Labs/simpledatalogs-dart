import 'dart:convert';

import 'outbox_storage.dart';
import 'sdk_log.dart';

/// The size limits the outbox enforces.
class OutboxLimits {
  /// The most events one sealed batch may hold.
  final int maxBatchEventCount;

  /// The most bytes one sealed batch (one request body, before gzip) may hold.
  final int maxBatchBytes;

  /// The most events kept across the journal and every sealed batch.
  final int maxTotalEventCount;

  /// The most bytes kept across the journal and every sealed batch.
  final int maxTotalBytes;

  /// The most sealed batch files kept, so days offline never leave thousands of files.
  final int maxSealedBatchCount;

  /// The ingest API defaults for apps; tests shrink them.
  const OutboxLimits({
    this.maxBatchEventCount = 50,
    this.maxBatchBytes = 256000,
    this.maxTotalEventCount = 10000,
    this.maxTotalBytes = 10 * 1024 * 1024,
    this.maxSealedBatchCount = 500,
  });
}

/// One sealed batch: an NDJSON request body waiting for its 202.
class SealedBatch {
  /// The storage entry name, which also orders batches oldest first.
  final String name;

  /// How many events (lines) the batch holds.
  final int eventCount;

  /// The body size in bytes, newlines included.
  final int byteCount;

  /// Describes one batch already in storage.
  const SealedBatch({required this.name, required this.eventCount, required this.byteCount});
}

/// What happened to a batch the server called too large.
enum BatchSplitOutcome {
  /// The batch was replaced by its two halves.
  split,

  /// The batch held one event, which was dropped because it can never be accepted.
  droppedLoneEvent,
}

/// The crash-safe outbox: an append-only journal, plus sealed batches deleted only after a 202.
class EventOutbox {
  /// The live journal every tracked event is appended to.
  static const String journalName = 'journal.ndjson';

  /// Every sealed batch name starts with this.
  static const String batchPrefix = 'batch-';

  /// Journals and sealed batches both end with this.
  static const String batchExtension = '.ndjson';

  /// The extension a batch gets once it failed to read too often.
  static const String unreadableExtension = '.unreadable';

  /// The extension a batch gets when ingest refused it as unsupported (415); it is never resent.
  static const String unsupportedExtension = '.unsupported';

  /// Reads of one batch that may fail in a row before it is set aside.
  static const int maxBatchReadAttempts = 3;

  /// Where every entry lives.
  final OutboxStorage storage;

  /// Batch and total size limits.
  final OutboxLimits limits;

  /// How many events the journal holds right now.
  int journalEventCount = 0;

  /// How many bytes the journal holds right now.
  int journalByteCount = 0;

  /// When the journal's first event was appended, for the batch timer.
  DateTime? journalStartedAt;

  /// Every sealed batch, oldest first.
  final List<SealedBatch> sealedBatches = [];

  /// Failed reads per batch name, reset by a good read.
  final Map<String, int> _readFailureCounts = {};

  /// A per-launch counter that keeps names sorted within one millisecond.
  int _nameSequence = 0;

  /// True once the cap dropped events, so a long offline period logs once.
  bool _hasLoggedCapDrop = false;

  /// Points the outbox at its storage; nothing is read until `recoverAfterLaunch`.
  EventOutbox(this.storage, {this.limits = const OutboxLimits()});

  /// Events held across the journal and every sealed batch.
  int get totalEventCount => journalEventCount + sealedBatches.fold(0, (sum, batch) => sum + batch.eventCount);

  /// Bytes held across the journal and every sealed batch.
  int get totalByteCount => journalByteCount + sealedBatches.fold(0, (sum, batch) => sum + batch.byteCount);

  /// The batch the send loop should try next.
  SealedBatch? get oldestSealedBatch => sealedBatches.isEmpty ? null : sealedBatches.first;

  /// The cheapest batch to send as a 401 re-probe.
  SealedBatch? get smallestSealedBatch {
    if (sealedBatches.isEmpty) {
      return null;
    }

    return sealedBatches.reduce((smallest, batch) => batch.byteCount < smallest.byteCount ? batch : smallest);
  }

  /// The bytes one event line takes in a body, including its newline.
  static int storedByteCount(String eventLine) => utf8.encode(eventLine).length + 1;

  /// Seals what earlier runs journaled but never sealed, indexes every sealed batch, and applies the caps.
  Future<void> recoverAfterLaunch(DateTime now) async {
    // A journal cut short by a crash still holds whole events worth sending.
    final leftoverJournal = await storage.read(journalName);
    if (leftoverJournal != null) {
      final recoveredLines = _wholeEventLines(leftoverJournal);

      if (recoveredLines.isNotEmpty) {
        await storage.write(_newBatchName(now), recoveredLines.map((eventLine) => '$eventLine\n').join());
      }

      await storage.delete(journalName);
    }

    // Index every sealed batch, oldest first.
    sealedBatches.clear();
    final batchNames = (await storage.listNames()).where(_isSealedBatchName).toList()..sort();
    for (final batchName in batchNames) {
      final batchText = await storage.read(batchName);
      if (batchText != null) {
        sealedBatches.add(_describeBatch(batchName, batchText));
      }
    }

    // A long offline period may have pushed the outbox over its cap.
    await enforceCap();
  }

  /// True when the journal must be sealed before this line: it holds a full batch, or the line would overfill a request.
  bool wouldJournalOverflow(String eventLine) {
    if (journalEventCount == 0) {
      return false;
    }

    final isJournalFull = journalEventCount >= limits.maxBatchEventCount;
    final wouldExceedRequestBytes = journalByteCount + storedByteCount(eventLine) > limits.maxBatchBytes;

    return isJournalFull || wouldExceedRequestBytes;
  }

  /// True when the journal holds a full batch and should be sealed and sent now.
  bool get isJournalFull => journalEventCount >= limits.maxBatchEventCount;

  /// Appends one encoded event line, so a crash from here on loses nothing.
  Future<void> appendToJournal(String eventLine, DateTime now) async {
    await storage.append(journalName, '$eventLine\n');

    // Count it only once it is stored.
    journalStartedAt ??= now;
    journalEventCount += 1;
    journalByteCount += storedByteCount(eventLine);
  }

  /// Turns the journal into a sealed batch, ready to send; does nothing when it is empty.
  Future<void> sealJournal(DateTime now) async {
    if (journalEventCount == 0) {
      return;
    }

    // An atomic rename, so the events are either in the journal or in the batch.
    final batchName = _newBatchName(now);
    await storage.rename(journalName, batchName);

    sealedBatches.add(SealedBatch(name: batchName, eventCount: journalEventCount, byteCount: journalByteCount));
    _resetJournalCounters();

    await enforceCap();
  }

  /// The batch body, or null when it cannot be read; a batch failing three reads in a row is set aside.
  Future<String?> readBatch(SealedBatch batch) async {
    try {
      final batchText = await storage.read(batch.name);

      // A batch that vanished from storage is simply forgotten.
      if (batchText == null) {
        sealedBatches.remove(batch);
        return null;
      }

      _readFailureCounts.remove(batch.name);
      return batchText;
    } catch (readError) {
      // Count the failure, and set the batch aside once it keeps failing, so it cannot block newer ones.
      final failureCount = (_readFailureCounts[batch.name] ?? 0) + 1;
      _readFailureCounts[batch.name] = failureCount;
      SdkLog.warning('Could not read ${batch.name} ($failureCount of $maxBatchReadAttempts): $readError');

      if (failureCount >= maxBatchReadAttempts) {
        await _setAside(batch, unreadableExtension);
      }

      return null;
    }
  }

  /// Deletes a batch after its 202.
  Future<void> deleteBatch(SealedBatch batch) async {
    await storage.delete(batch.name);
    sealedBatches.remove(batch);
  }

  /// Sets a batch ingest refused as unsupported (415) aside, never to be resent.
  Future<void> setAsideUnsupported(SealedBatch batch) => _setAside(batch, unsupportedExtension);

  /// Replaces a batch the server called too large with its two halves, or drops it when it holds one event.
  Future<BatchSplitOutcome> splitBatch(SealedBatch batch, String batchText) async {
    final eventLines = _wholeEventLines(batchText);

    // One event that is still too large can never be accepted.
    if (eventLines.length <= 1) {
      await deleteBatch(batch);
      SdkLog.warning('Dropped one event larger than the ingest body limit');
      return BatchSplitOutcome.droppedLoneEvent;
    }

    // Write both halves under names that sort where the original was, then drop the original.
    final halfIndex = eventLines.length ~/ 2;
    final baseName = batch.name.substring(0, batch.name.length - batchExtension.length);
    final halves = [eventLines.sublist(0, halfIndex), eventLines.sublist(halfIndex)];
    final halfBatches = <SealedBatch>[];

    for (var halfIndexInList = 0; halfIndexInList < halves.length; halfIndexInList += 1) {
      final halfName = '$baseName-${halfIndexInList + 1}$batchExtension';
      final halfText = halves[halfIndexInList].map((eventLine) => '$eventLine\n').join();

      await storage.write(halfName, halfText);
      halfBatches.add(_describeBatch(halfName, halfText));
    }

    await storage.delete(batch.name);

    // Keep the index in name order.
    sealedBatches
      ..remove(batch)
      ..addAll(halfBatches)
      ..sort((firstBatch, secondBatch) => firstBatch.name.compareTo(secondBatch.name));

    return BatchSplitOutcome.split;
  }

  /// Deletes the journal and every batch, for an opt-out.
  Future<void> deleteEverything() async {
    for (final entryName in await storage.listNames()) {
      final isOutboxEntry = entryName == journalName || entryName.startsWith(batchPrefix);

      if (isOutboxEntry) {
        await storage.delete(entryName);
      }
    }

    sealedBatches.clear();
    _resetJournalCounters();
  }

  /// Drops the oldest sealed batches while the outbox is over any cap.
  Future<void> enforceCap() async {
    var droppedEventCount = 0;

    // The journal is never dropped: it holds the newest events.
    while (sealedBatches.isNotEmpty && _isOverCap) {
      final oldestBatch = sealedBatches.first;
      await storage.delete(oldestBatch.name);
      sealedBatches.removeAt(0);
      droppedEventCount += oldestBatch.eventCount;
    }

    // Log the first drop, so a long offline period does not flood the log.
    if (droppedEventCount > 0 && !_hasLoggedCapDrop) {
      _hasLoggedCapDrop = true;
      SdkLog.warning('The outbox is full; dropped the $droppedEventCount oldest unsent events');
    }
  }

  // True while the outbox holds more events, bytes or batch files than allowed.
  bool get _isOverCap {
    return totalEventCount > limits.maxTotalEventCount ||
        totalByteCount > limits.maxTotalBytes ||
        sealedBatches.length > limits.maxSealedBatchCount;
  }

  // Renames a batch with an extra extension, so it is no longer indexed or sent.
  Future<void> _setAside(SealedBatch batch, String extension) async {
    try {
      await storage.rename(batch.name, '${batch.name}$extension');
    } catch (renameError) {
      SdkLog.warning('Could not set ${batch.name} aside: $renameError');
    }

    sealedBatches.remove(batch);
    _readFailureCounts.remove(batch.name);
  }

  // Zeroes the journal counters after a seal or a wipe.
  void _resetJournalCounters() {
    journalEventCount = 0;
    journalByteCount = 0;
    journalStartedAt = null;
  }

  // A fresh batch name: epoch milliseconds, then a sequence, so names sort oldest first.
  String _newBatchName(DateTime now) {
    _nameSequence += 1;

    final millisecondsText = now.millisecondsSinceEpoch.toString().padLeft(13, '0');
    final sequenceText = _nameSequence.toString().padLeft(6, '0');

    return '$batchPrefix$millisecondsText-$sequenceText$batchExtension';
  }

  // True for live batch names, false for set-aside ones and every other entry.
  static bool _isSealedBatchName(String entryName) {
    return entryName.startsWith(batchPrefix) && entryName.endsWith(batchExtension);
  }

  // Counts a batch's events and bytes from its text.
  static SealedBatch _describeBatch(String batchName, String batchText) {
    final eventLines = _wholeEventLines(batchText);
    final byteCount = eventLines.fold(0, (sum, eventLine) => sum + storedByteCount(eventLine));

    return SealedBatch(name: batchName, eventCount: eventLines.length, byteCount: byteCount);
  }

  // The complete JSON object lines of a body; a partial last line from a crash mid-write is dropped.
  static List<String> _wholeEventLines(String bodyText) {
    final rawLines = bodyText.split('\n');

    // Text after the last newline was never finished.
    if (!bodyText.endsWith('\n')) {
      rawLines.removeLast();
    }

    return rawLines.where(_isJsonObjectLine).toList();
  }

  // True when a line parses as one JSON object.
  static bool _isJsonObjectLine(String candidateLine) {
    if (!candidateLine.startsWith('{')) {
      return false;
    }

    try {
      return jsonDecode(candidateLine) is Map;
    } on FormatException {
      return false;
    }
  }
}
