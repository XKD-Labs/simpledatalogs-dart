import 'dart:io';

/// False on the Dart VM, Flutter mobile and desktop: User-Agent and gzip are available.
const bool isRunningOnWeb = false;

/// Gzips a request body.
List<int>? gzipBytes(List<int> bodyBytes) => gzip.encode(bodyBytes);
