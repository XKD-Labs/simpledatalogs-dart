import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:simpledatalogs/io.dart';
import 'package:simpledatalogs/simpledatalogs.dart';

/// The outbox folder inside the app's own support folder, which is never shown to the user.
Future<OutboxStorage?> makeDefaultStorage() async {
  final supportDirectory = await getApplicationSupportDirectory();

  return FileOutboxStorage(Directory('${supportDirectory.path}${Platform.pathSeparator}simpledatalogs'));
}
