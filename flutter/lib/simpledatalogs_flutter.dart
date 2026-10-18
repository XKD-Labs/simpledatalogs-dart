/// Flutter wiring for simpledatalogs: disk outbox, lifecycle flushes, errors and screen views.
///
/// Start with `SimpleDataLogsFlutter.configure`, then call `SimpleDataLogs.track`.
library;

export 'package:simpledatalogs/simpledatalogs.dart';

export 'src/navigator_observer.dart' show SimpleDataLogsNavigatorObserver;
export 'src/simpledatalogs_flutter.dart' show SimpleDataLogsFlutter;
