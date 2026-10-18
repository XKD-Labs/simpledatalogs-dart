/// Where the outbox keeps its named text files: a folder on disk, or memory.
///
/// Implement it to keep the outbox somewhere else, e.g. a database table.
abstract class OutboxStorage {
  /// The names of every stored entry, in no particular order.
  Future<List<String>> listNames();

  /// The entry's text, or null when it does not exist.
  Future<String?> read(String name);

  /// Replaces the entry's text atomically, so a crash leaves the old or the new text, never half.
  Future<void> write(String name, String text);

  /// Appends text to the entry, creating it when missing; this is the per-event write, so keep it cheap.
  Future<void> append(String name, String text);

  /// Renames an entry atomically, replacing any entry already called `newName`.
  Future<void> rename(String oldName, String newName);

  /// Deletes the entry; a missing entry is not an error.
  Future<void> delete(String name);
}

/// Keeps the outbox in memory: nothing survives a restart, but nothing touches the disk.
///
/// The default when no storage is given, and the only choice on the web.
class MemoryOutboxStorage implements OutboxStorage {
  /// Every entry by name.
  final Map<String, String> _entries = {};

  @override
  Future<List<String>> listNames() async => _entries.keys.toList();

  @override
  Future<String?> read(String name) async => _entries[name];

  @override
  Future<void> write(String name, String text) async {
    _entries[name] = text;
  }

  @override
  Future<void> append(String name, String text) async {
    _entries[name] = (_entries[name] ?? '') + text;
  }

  @override
  Future<void> rename(String oldName, String newName) async {
    final entryText = _entries.remove(oldName);
    if (entryText != null) {
      _entries[newName] = entryText;
    }
  }

  @override
  Future<void> delete(String name) async {
    _entries.remove(name);
  }
}
