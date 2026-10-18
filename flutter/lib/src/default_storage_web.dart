import 'package:simpledatalogs/simpledatalogs.dart';

/// Browsers have no folder to write to, so the outbox stays in memory.
Future<OutboxStorage?> makeDefaultStorage() async => null;
