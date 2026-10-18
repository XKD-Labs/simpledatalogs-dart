import 'package:flutter/widgets.dart';
import 'package:simpledatalogs/simpledatalogs.dart';

/// Turns a route into a screen name, or null to skip it.
typedef ScreenNameExtractor = String? Function(RouteSettings settings);

/// Sends `screen_view` whenever a named page route becomes visible; add it to `navigatorObservers`.
class SimpleDataLogsNavigatorObserver extends NavigatorObserver {
  /// Reads the screen name from a route; by default its `settings.name`.
  final ScreenNameExtractor screenNameExtractor;

  /// Creates an observer; pass `screenNameExtractor` to name routes your own way.
  SimpleDataLogsNavigatorObserver({this.screenNameExtractor = _routeName});

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _trackScreenOf(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _trackScreenOf(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);

    // Popping back reveals the previous screen again.
    _trackScreenOf(previousRoute);
  }

  // Tracks a page route that has a name; dialogs and popups are skipped.
  void _trackScreenOf(Route<dynamic>? route) {
    if (route is! PageRoute) {
      return;
    }

    final screenName = screenNameExtractor(route.settings);
    if (screenName == null || screenName.isEmpty) {
      return;
    }

    SimpleDataLogs.trackScreen(screenName);
  }

  // The default extractor: the route's own name.
  static String? _routeName(RouteSettings settings) => settings.name;
}
