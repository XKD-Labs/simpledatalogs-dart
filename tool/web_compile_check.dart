import 'package:simpledatalogs/simpledatalogs.dart';

/// Compiled with `dart compile js` in CI, to prove the core never imports `dart:io` on the web.
void main() {
  SimpleDataLogs.configure(ingestKey: 'sdl_pub_web_compile_check');
  SimpleDataLogs.track('web_compile_check');
}
