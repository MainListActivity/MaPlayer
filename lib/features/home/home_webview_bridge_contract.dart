class HomeWebViewBridgeContract {
  static const String playHandlerName = 'maPlayerPlay';
  static const String errorHandlerName = 'maPlayerBridgeError';
  static const int defaultRemoteTimeoutMs = 2000;

  static Map<String, dynamic> buildInitConfig({
    String? remoteJsUrl,
    int remoteTimeoutMs = defaultRemoteTimeoutMs,
  }) {
    final normalized = remoteJsUrl?.trim();
    return <String, dynamic>{
      'handlerName': playHandlerName,
      'errorHandlerName': errorHandlerName,
      'remoteJsUrl': (normalized == null || normalized.isEmpty)
          ? null
          : normalized,
      'remoteTimeoutMs': remoteTimeoutMs,
    };
  }
}
