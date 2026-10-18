/// True in browsers, which forbid setting a User-Agent and have no synchronous gzip.
const bool isRunningOnWeb = true;

/// Browsers have no synchronous gzip, so bodies go uncompressed.
List<int>? gzipBytes(List<int> bodyBytes) => null;
