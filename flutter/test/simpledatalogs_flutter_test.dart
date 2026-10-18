import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simpledatalogs_flutter/simpledatalogs_flutter.dart';

void main() {
  late List<String> sentBodies;
  late MockClient mockClient;

  setUp(() {
    sentBodies = [];
    mockClient = MockClient((request) async {
      sentBodies.add(request.body);
      return http.Response('{"accepted":"x"}', 202);
    });
  });

  testWidgets('falls back to memory without a platform folder, and tracks screens from the navigator', (tester) async {
    await tester.runAsync(() => SimpleDataLogsFlutter.configure(ingestKey: 'sdl_pub_test', httpClient: mockClient));

    // A named home route and one pushed screen.
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [SimpleDataLogsNavigatorObserver()],
        initialRoute: '/',
        routes: {
          '/': (_) => const Text('Home'),
          '/shop': (_) => const Text('Shop'),
        },
      ),
    );
    unawaited(navigatorKey.currentState!.pushNamed('/shop'));
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    await tester.runAsync(SimpleDataLogs.flush);

    final sentScreens = RegExp(r'"screen":"([^"]+)"').allMatches(sentBodies.join()).map((match) => match.group(1)).toList();
    expect(sentScreens, ['/', '/shop', '/']);
    await tester.runAsync(SimpleDataLogs.close);
  });

  testWidgets('flushes when the app is hidden', (tester) async {
    await tester.runAsync(() => SimpleDataLogsFlutter.configure(ingestKey: 'sdl_pub_test', httpClient: mockClient));
    await tester.runAsync(() async {
      SimpleDataLogs.track('level_start', {'level': 1});
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

      // The background flush runs on its own; give it a moment.
      for (var waitIndex = 0; waitIndex < 50 && sentBodies.isEmpty; waitIndex += 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    expect(sentBodies.single, contains('"event":"level_start"'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(SimpleDataLogs.close);
  });

  testWidgets('sends Flutter errors as app_error when asked', (tester) async {
    final previousHandler = FlutterError.onError;
    var previousHandlerCallCount = 0;
    FlutterError.onError = (_) => previousHandlerCallCount += 1;
    addTearDown(() => FlutterError.onError = previousHandler);

    await tester.runAsync(
      () => SimpleDataLogsFlutter.configure(
        ingestKey: 'sdl_pub_test',
        httpClient: mockClient,
        autocapture: const AutocaptureOptions(errors: true),
      ),
    );

    FlutterError.onError!(FlutterErrorDetails(exception: StateError('boom'), stack: StackTrace.current));
    await tester.runAsync(SimpleDataLogs.flush);

    expect(previousHandlerCallCount, 1);
    expect(sentBodies.single, contains('"event":"app_error"'));
    expect(sentBodies.single, contains('"source":"flutter"'));
    await tester.runAsync(SimpleDataLogs.close);
  });
}
