import 'dart:io';

import 'package:simpledatalogs/io.dart';
import 'package:simpledatalogs/simpledatalogs.dart';
import 'package:simpledatalogs/src/event_outbox.dart';
import 'package:test/test.dart';

/// A storage whose reads of one entry always fail, like a corrupt file.
class FailingReadStorage extends MemoryOutboxStorage {
  /// The entry name whose reads throw.
  String? failingEntryName;

  @override
  Future<String?> read(String name) {
    if (name == failingEntryName) {
      throw const FileSystemException('unreadable');
    }

    return super.read(name);
  }
}

// One small valid event line with a counter.
String eventLine(int eventNumber) => '{"event":"e$eventNumber","event_id":"id-$eventNumber","ts":"2026-10-19T12:00:00.000Z","props":{}}';

void main() {
  final now = DateTime.utc(2026, 10, 19, 12);

  // Journal and sealing.
  group('EventOutbox journal', () {
    test('appends events and seals them into one batch', () async {
      final outbox = EventOutbox(MemoryOutboxStorage());
      await outbox.recoverAfterLaunch(now);

      await outbox.appendToJournal(eventLine(1), now);
      await outbox.appendToJournal(eventLine(2), now);
      expect(outbox.journalEventCount, 2);
      expect(outbox.journalStartedAt, now);

      await outbox.sealJournal(now);
      expect(outbox.journalEventCount, 0);
      expect(outbox.sealedBatches.single.eventCount, 2);
      expect(await outbox.readBatch(outbox.sealedBatches.single), '${eventLine(1)}\n${eventLine(2)}\n');
    });

    test('asks for a seal at 50 events or before passing the request byte limit', () async {
      final outbox = EventOutbox(MemoryOutboxStorage(), limits: const OutboxLimits(maxBatchEventCount: 3, maxBatchBytes: 300));

      // Count limit.
      for (var eventNumber = 0; eventNumber < 3; eventNumber += 1) {
        expect(outbox.wouldJournalOverflow(eventLine(eventNumber)), isFalse);
        await outbox.appendToJournal(eventLine(eventNumber), now);
      }
      expect(outbox.isJournalFull, isTrue);
      expect(outbox.wouldJournalOverflow(eventLine(9)), isTrue);

      // Byte limit.
      await outbox.sealJournal(now);
      await outbox.appendToJournal(eventLine(1), now);
      expect(outbox.wouldJournalOverflow('{"event":"${'x' * 250}"}'), isTrue);
    });

    test('keeps names in oldest-first order', () async {
      final outbox = EventOutbox(MemoryOutboxStorage());

      for (var eventNumber = 0; eventNumber < 12; eventNumber += 1) {
        await outbox.appendToJournal(eventLine(eventNumber), now);
        await outbox.sealJournal(now);
      }

      final batchNames = outbox.sealedBatches.map((batch) => batch.name).toList();
      expect(batchNames, [...batchNames]..sort());
      expect(await outbox.readBatch(outbox.oldestSealedBatch!), '${eventLine(0)}\n');
    });
  });

  // Caps.
  group('EventOutbox caps', () {
    test('drops the oldest batches past the event cap', () async {
      final outbox = EventOutbox(MemoryOutboxStorage(), limits: const OutboxLimits(maxTotalEventCount: 4));

      for (var eventNumber = 0; eventNumber < 6; eventNumber += 1) {
        await outbox.appendToJournal(eventLine(eventNumber), now);
        await outbox.sealJournal(now);
      }

      expect(outbox.totalEventCount, 4);
      expect(await outbox.readBatch(outbox.oldestSealedBatch!), '${eventLine(2)}\n');
    });

    test('drops the oldest batches past the byte and file caps', () async {
      final byteCappedOutbox = EventOutbox(MemoryOutboxStorage(), limits: const OutboxLimits(maxTotalBytes: 250));
      final fileCappedOutbox = EventOutbox(MemoryOutboxStorage(), limits: const OutboxLimits(maxSealedBatchCount: 2));

      for (var eventNumber = 0; eventNumber < 5; eventNumber += 1) {
        for (final outbox in [byteCappedOutbox, fileCappedOutbox]) {
          await outbox.appendToJournal(eventLine(eventNumber), now);
          await outbox.sealJournal(now);
        }
      }

      expect(byteCappedOutbox.totalByteCount <= 250, isTrue);
      expect(fileCappedOutbox.sealedBatches.length, 2);
    });
  });

  // 413 splits.
  group('EventOutbox.splitBatch', () {
    test('replaces a batch by two halves in its place', () async {
      final outbox = EventOutbox(MemoryOutboxStorage());

      for (var eventNumber = 0; eventNumber < 5; eventNumber += 1) {
        await outbox.appendToJournal(eventLine(eventNumber), now);
      }
      await outbox.sealJournal(now);
      await outbox.appendToJournal(eventLine(9), now);
      await outbox.sealJournal(now.add(const Duration(seconds: 1)));

      final firstBatch = outbox.oldestSealedBatch!;
      final outcome = await outbox.splitBatch(firstBatch, (await outbox.readBatch(firstBatch))!);

      expect(outcome, BatchSplitOutcome.split);
      expect(outbox.sealedBatches.map((batch) => batch.eventCount), [2, 3, 1]);
      expect(outbox.totalEventCount, 6);
    });

    test('drops a lone event that is still too large', () async {
      final outbox = EventOutbox(MemoryOutboxStorage());
      await outbox.appendToJournal(eventLine(1), now);
      await outbox.sealJournal(now);

      final loneBatch = outbox.oldestSealedBatch!;
      final outcome = await outbox.splitBatch(loneBatch, (await outbox.readBatch(loneBatch))!);

      expect(outcome, BatchSplitOutcome.droppedLoneEvent);
      expect(outbox.sealedBatches, isEmpty);
    });
  });

  // Launch recovery.
  group('EventOutbox.recoverAfterLaunch', () {
    test('seals a journal cut short by a crash, dropping the partial line', () async {
      final storage = MemoryOutboxStorage();
      await storage.write(EventOutbox.journalName, '${eventLine(1)}\n${eventLine(2)}\n{"event":"half');

      final outbox = EventOutbox(storage);
      await outbox.recoverAfterLaunch(now);

      expect(outbox.journalEventCount, 0);
      expect(outbox.sealedBatches.single.eventCount, 2);
      expect(await storage.read(EventOutbox.journalName), isNull);
    });

    test('indexes batches a previous run left on disk', () async {
      final outboxDirectory = await Directory.systemTemp.createTemp('sdl-outbox-');
      addTearDown(() => outboxDirectory.delete(recursive: true));

      // A first run seals one batch and journals one more event.
      final firstRunOutbox = EventOutbox(FileOutboxStorage(outboxDirectory));
      await firstRunOutbox.recoverAfterLaunch(now);
      await firstRunOutbox.appendToJournal(eventLine(1), now);
      await firstRunOutbox.sealJournal(now);
      await firstRunOutbox.appendToJournal(eventLine(2), now);

      // The next run finds both.
      final secondRunOutbox = EventOutbox(FileOutboxStorage(outboxDirectory));
      await secondRunOutbox.recoverAfterLaunch(now.add(const Duration(minutes: 1)));

      expect(secondRunOutbox.sealedBatches.length, 2);
      expect(secondRunOutbox.totalEventCount, 2);
    });
  });

  // Unreadable batches.
  test('sets a batch aside after three failed reads', () async {
    final storage = FailingReadStorage();
    final outbox = EventOutbox(storage);
    await outbox.appendToJournal(eventLine(1), now);
    await outbox.sealJournal(now);

    final brokenBatch = outbox.oldestSealedBatch!;
    storage.failingEntryName = brokenBatch.name;

    for (var attempt = 0; attempt < EventOutbox.maxBatchReadAttempts; attempt += 1) {
      expect(await outbox.readBatch(brokenBatch), isNull);
    }

    expect(outbox.sealedBatches, isEmpty);
    expect(await storage.listNames(), ['${brokenBatch.name}${EventOutbox.unreadableExtension}']);
  });

  // Opt-out.
  test('deleteEverything removes the journal and every batch', () async {
    final storage = MemoryOutboxStorage();
    final outbox = EventOutbox(storage);
    await outbox.appendToJournal(eventLine(1), now);
    await outbox.sealJournal(now);
    await outbox.appendToJournal(eventLine(2), now);

    await outbox.deleteEverything();

    expect(outbox.totalEventCount, 0);
    expect(await storage.listNames(), isEmpty);
  });
}
