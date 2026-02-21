enum ProxyMode { parallel, single }

class ProxySessionDescriptor {
  const ProxySessionDescriptor({
    required this.sessionId,
    required this.sourceUrl,
    required this.headers,
    required this.mode,
    required this.createdAt,
    this.contentLength,
  });

  final String sessionId;
  final String sourceUrl;
  final Map<String, String> headers;
  final ProxyMode mode;
  final DateTime createdAt;
  final int? contentLength;
}

class ProxyStatsSnapshot {
  const ProxyStatsSnapshot({
    required this.sessionId,
    required this.downloadBps,
    required this.serveBps,
    required this.cacheHitRate,
    required this.activeWorkers,
    required this.bufferedBytesAhead,
    required this.mode,
    required this.updatedAt,
  });

  final String sessionId;
  final double downloadBps;
  final double serveBps;
  final double cacheHitRate;
  final int activeWorkers;
  final int bufferedBytesAhead;
  final ProxyMode mode;
  final DateTime updatedAt;
}

class ProxyAggregateStats {
  const ProxyAggregateStats({
    required this.proxyRunning,
    required this.downloadBps,
    required this.bufferedBytesAhead,
    required this.activeWorkers,
    required this.updatedAt,
  });

  final bool proxyRunning;
  final double downloadBps;
  final int bufferedBytesAhead;
  final int activeWorkers;
  final DateTime updatedAt;
}
