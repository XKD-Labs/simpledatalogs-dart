import 'dart:io';

import 'outbox_storage.dart';

/// Keeps the outbox in a folder on disk, so events survive crashes and restarts.
///
/// On Flutter, pass a folder from path_provider's `getApplicationSupportDirectory()`.
class FileOutboxStorage implements OutboxStorage {
  /// The folder holding the outbox files; created on the first write.
  final Directory directory;

  /// Points the storage at a folder; nothing touches the disk until the first call.
  FileOutboxStorage(this.directory);

  @override
  Future<List<String>> listNames() async {
    // A folder that does not exist yet holds nothing.
    if (!await directory.exists()) {
      return [];
    }

    // Only plain files count; temporary files from an interrupted write are skipped.
    final folderEntries = await directory.list(followLinks: false).toList();

    return folderEntries
        .whereType<File>()
        .map((outboxFile) => outboxFile.uri.pathSegments.last)
        .where((fileName) => !fileName.endsWith('.tmp'))
        .toList();
  }

  @override
  Future<String?> read(String name) async {
    final outboxFile = _fileNamed(name);

    // A missing file reads as null instead of throwing.
    if (!await outboxFile.exists()) {
      return null;
    }

    return outboxFile.readAsString();
  }

  @override
  Future<void> write(String name, String text) async {
    await directory.create(recursive: true);

    // Write a temporary file, then rename it over the target, so a crash leaves one whole version.
    final temporaryFile = _fileNamed('$name.tmp');
    await temporaryFile.writeAsString(text, flush: true);
    await temporaryFile.rename(_fileNamed(name).path);
  }

  @override
  Future<void> append(String name, String text) async {
    await directory.create(recursive: true);

    // Flush each append, so an event is on disk before `track` work moves on.
    await _fileNamed(name).writeAsString(text, mode: FileMode.append, flush: true);
  }

  @override
  Future<void> rename(String oldName, String newName) async {
    final oldFile = _fileNamed(oldName);

    if (await oldFile.exists()) {
      await oldFile.rename(_fileNamed(newName).path);
    }
  }

  @override
  Future<void> delete(String name) async {
    final outboxFile = _fileNamed(name);

    if (await outboxFile.exists()) {
      await outboxFile.delete();
    }
  }

  // The file for one entry name inside the folder.
  File _fileNamed(String name) => File('${directory.path}${Platform.pathSeparator}$name');
}
