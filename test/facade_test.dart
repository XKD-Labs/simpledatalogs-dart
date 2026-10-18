import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simpledatalogs/simpledatalogs.dart';
import 'package:test/test.dart';

void main() {
  tearDown(SimpleDataLogs.close);

  test('the facade drops events tracked before configure, then sends the rest', () async {
    final sentBodies = <String>[];
    final mockClient = MockClient((request) async {
      sentBodies.add(request.body);
      return http.Response('{"accepted":"x"}', 202);
    });

    // Before configure: dropped with a log line, never thrown.
    SimpleDataLogs.track('too_early');

    // Settings made before configure apply once it runs.
    SimpleDataLogs.setDeviceId('device-9');
    SimpleDataLogs.setDefaultProperties({'app_version': '2.0.0'});
    SimpleDataLogs.configure(ingestKey: 'sdl_pub_test', httpClient: mockClient);
    SimpleDataLogs.configure(ingestKey: 'sdl_pub_ignored', httpClient: mockClient);
    SimpleDataLogs.trackScreen('Shop', {'tab': 'gems'});

    await SimpleDataLogs.flush();

    expect(sentBodies.length, 1);
    expect(sentBodies.single, contains('"event":"screen_view"'));
    expect(sentBodies.single, contains('"device_id":"device-9"'));
    expect(sentBodies.single, contains('"app_version":"2.0.0"'));
    expect(sentBodies.single, isNot(contains('too_early')));
  });

  test('an opt-out before configure sends nothing', () async {
    var requestCount = 0;
    final mockClient = MockClient((request) async {
      requestCount += 1;
      return http.Response('', 202);
    });

    SimpleDataLogs.setEnabled(false);
    SimpleDataLogs.configure(ingestKey: 'sdl_pub_test', httpClient: mockClient);
    SimpleDataLogs.track('never_sent');
    await SimpleDataLogs.flush();

    expect(requestCount, 0);
    SimpleDataLogs.setEnabled(true);
  });

  test('a throwing log handler never reaches the caller', () {
    final previousHandler = SdkLog.handler;
    addTearDown(() => SdkLog.handler = previousHandler);
    SdkLog.handler = (level, message) => throw StateError('broken logger');

    expect(() => SimpleDataLogs.track(''), returnsNormally);
  });
}
