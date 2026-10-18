import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One request the fake server received, already decompressed.
class ReceivedRequest {
  /// Request headers, lowercased names.
  final Map<String, String> headers;

  /// The NDJSON body as text.
  final String bodyText;

  /// The body size as sent, compressed or not.
  final int sentByteCount;

  /// Captures one request.
  ReceivedRequest({required this.headers, required this.bodyText, required this.sentByteCount});

  /// Every event in the body, decoded.
  List<Map<String, Object?>> get events {
    return bodyText
        .split('\n')
        .where((bodyLine) => bodyLine.isNotEmpty)
        .map((bodyLine) => jsonDecode(bodyLine) as Map<String, Object?>)
        .toList();
  }
}

/// A scripted answer: a status and optional headers.
class ScriptedAnswer {
  /// The HTTP status to answer.
  final int statusCode;

  /// Extra response headers, e.g. Retry-After.
  final Map<String, String> headers;

  /// Builds an answer.
  const ScriptedAnswer(this.statusCode, {this.headers = const {}});
}

/// A real local HTTP server that answers `/v1/ingest` from a script, then 202 once the script runs out.
class FakeIngestServer {
  /// Every request received, in order.
  final List<ReceivedRequest> requests = [];

  /// Answers still to give, first one next.
  final List<ScriptedAnswer> scriptedAnswers;

  /// The bound server.
  late final HttpServer _httpServer;

  /// Completes each time a request arrives.
  final StreamController<ReceivedRequest> _requestStream = StreamController.broadcast();

  /// Builds a server with an answer script.
  FakeIngestServer([List<ScriptedAnswer>? scriptedAnswers]) : scriptedAnswers = scriptedAnswers ?? [];

  /// The endpoint to configure the SDK with.
  Uri get endpoint => Uri.parse('http://127.0.0.1:${_httpServer.port}');

  /// Every event id the server answered 202 for.
  List<String> acceptedEventIds = [];

  /// Starts listening on a free port.
  Future<void> start() async {
    _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _httpServer.listen(_handleRequest);
  }

  /// Stops the server.
  Future<void> stop() => _httpServer.close(force: true);

  /// Waits until the server has received at least this many requests.
  Future<void> waitForRequests(int requestCount, {Duration timeout = const Duration(seconds: 10)}) async {
    if (requests.length >= requestCount) {
      return;
    }

    await _requestStream.stream.firstWhere((_) => requests.length >= requestCount).timeout(timeout);
  }

  // Reads one request, decompresses it, and answers from the script.
  Future<void> _handleRequest(HttpRequest httpRequest) async {
    // Collect the body bytes as sent.
    final sentBytes = await httpRequest.fold<List<int>>([], (allBytes, chunk) => allBytes..addAll(chunk));
    final isGzipped = httpRequest.headers.value('content-encoding') == 'gzip';
    final bodyText = utf8.decode(isGzipped ? gzip.decode(sentBytes) : sentBytes);

    // Keep every header under its lowercase name.
    final headers = <String, String>{};
    httpRequest.headers.forEach((headerName, headerValues) => headers[headerName.toLowerCase()] = headerValues.join(','));

    final receivedRequest = ReceivedRequest(headers: headers, bodyText: bodyText, sentByteCount: sentBytes.length);
    requests.add(receivedRequest);

    // Answer from the script, then 202 for everything after it.
    final answer = scriptedAnswers.isEmpty ? const ScriptedAnswer(202) : scriptedAnswers.removeAt(0);
    if (answer.statusCode == 202) {
      acceptedEventIds.addAll(receivedRequest.events.map((event) => event['event_id'] as String));
    }

    httpRequest.response.statusCode = answer.statusCode;
    answer.headers.forEach(httpRequest.response.headers.set);
    httpRequest.response.write(answer.statusCode == 202 ? '{"accepted":"test"}' : '{"error":"scripted"}');
    await httpRequest.response.close();

    _requestStream.add(receivedRequest);
  }
}
