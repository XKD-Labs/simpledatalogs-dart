import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'retry_policy.dart';
import 'version.dart';
import 'platform/platform_web.dart' if (dart.library.io) 'platform/platform_io.dart' as platform;

/// What one ingest answer means for the batch that was sent.
sealed class IngestOutcome {
  /// Builds an outcome.
  const IngestOutcome();

  /// Maps an HTTP status and its Retry-After header onto the ingest API response table.
  factory IngestOutcome.fromStatus(int statusCode, String? retryAfterHeader, DateTime now) {
    return switch (statusCode) {
      202 => const IngestAccepted(),
      401 => const IngestInvalidKey(),
      413 => const IngestPayloadTooLarge(),
      415 => const IngestUnsupported(),

      // Anything else, including other 2xx codes, was not stored, so it is retried.
      _ => IngestRetryable(RetryAfterHeader.delay(retryAfterHeader, now), 'HTTP $statusCode'),
    };
  }
}

/// 202: durably stored, so the batch leaves the outbox.
class IngestAccepted extends IngestOutcome {
  /// The single success answer.
  const IngestAccepted();
}

/// 401: the key is unknown, revoked or not yet live, so sending pauses and re-probes slowly.
class IngestInvalidKey extends IngestOutcome {
  /// The bad-key answer.
  const IngestInvalidKey();
}

/// 413: the body was too large, so the batch is split in half.
class IngestPayloadTooLarge extends IngestOutcome {
  /// The too-large answer.
  const IngestPayloadTooLarge();
}

/// 415: ingest can never take this batch as it is, so it is set aside.
class IngestUnsupported extends IngestOutcome {
  /// The unsupported answer.
  const IngestUnsupported();
}

/// 429, 503, any other status, a timeout or a network error: keep the batch and retry.
class IngestRetryable extends IngestOutcome {
  /// The server's Retry-After, when it sent a readable one.
  final Duration? retryAfter;

  /// A short reason for the log.
  final String reason;

  /// A retryable answer with its hint.
  const IngestRetryable(this.retryAfter, this.reason);
}

/// Posts NDJSON batches to `<endpoint>/v1/ingest` with the ingest API headers.
class IngestClient {
  /// The User-Agent every request carries where the platform allows one.
  static const String userAgent = 'simpledatalogs-dart/$sdkVersion';

  /// Bodies this size or larger are gzipped.
  static const int gzipThresholdBytes = 1024;

  /// The full ingest URL.
  final Uri ingestUrl;

  /// The bearer key.
  final String ingestKey;

  /// How long one request may take.
  final Duration requestTimeout;

  /// The HTTP client every request goes through; tests inject their own.
  final http.Client httpClient;

  /// Creates a client for one key and URL.
  IngestClient(
      {required this.ingestUrl, required this.ingestKey, required this.httpClient, this.requestTimeout = const Duration(seconds: 30)});

  /// The ingest URL for an endpoint: `<endpoint>/v1/ingest`.
  static Uri ingestUrlFor(Uri endpoint) {
    final endpointText = endpoint.toString();
    final baseText = endpointText.endsWith('/') ? endpointText.substring(0, endpointText.length - 1) : endpointText;

    return Uri.parse('$baseText/v1/ingest');
  }

  /// Builds the headers and body bytes for one batch, gzipping large bodies where possible.
  ({Map<String, String> headers, List<int> bodyBytes}) buildRequest(String batchText) {
    final plainBytes = utf8.encode(batchText);
    final headers = <String, String>{
      'Authorization': 'Bearer $ingestKey',
      'Content-Type': 'application/x-ndjson',
    };

    // Browsers refuse a custom User-Agent and send their own.
    if (!platform.isRunningOnWeb) {
      headers['User-Agent'] = userAgent;
    }

    // Small bodies are not worth compressing.
    if (plainBytes.length < gzipThresholdBytes) {
      return (headers: headers, bodyBytes: plainBytes);
    }

    // Compression failing is no reason not to send.
    try {
      final gzippedBytes = platform.gzipBytes(plainBytes);
      if (gzippedBytes != null) {
        headers['Content-Encoding'] = 'gzip';
        return (headers: headers, bodyBytes: gzippedBytes);
      }
    } catch (_) {
      // Fall through to the plain body.
    }

    return (headers: headers, bodyBytes: plainBytes);
  }

  /// Sends one batch and classifies the answer; it never throws.
  Future<IngestOutcome> send(String batchText) async {
    try {
      final request = buildRequest(batchText);

      // Send the batch and wait for the status, within the timeout.
      final response = await httpClient.post(ingestUrl, headers: request.headers, body: request.bodyBytes).timeout(requestTimeout);

      return IngestOutcome.fromStatus(response.statusCode, response.headers['retry-after'], DateTime.now());
    } catch (sendError) {
      // Timeouts, offline and refused connections all leave the batch unconfirmed.
      return IngestRetryable(null, sendError.toString());
    }
  }
}
