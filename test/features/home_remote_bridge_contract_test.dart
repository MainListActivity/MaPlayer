import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/features/home/home_webview_bridge_contract.dart';

void main() {
  test('buildInitConfig keeps handlers and timeout defaults', () {
    final config = HomeWebViewBridgeContract.buildInitConfig();

    expect(config['handlerName'], HomeWebViewBridgeContract.playHandlerName);
    expect(
      config['errorHandlerName'],
      HomeWebViewBridgeContract.errorHandlerName,
    );
    expect(
      config['remoteTimeoutMs'],
      HomeWebViewBridgeContract.defaultRemoteTimeoutMs,
    );
    expect(config['remoteJsUrl'], isNull);
  });

  test('buildInitConfig normalizes optional remote url', () {
    final withRemote = HomeWebViewBridgeContract.buildInitConfig(
      remoteJsUrl: ' https://example.com/bridge.js ',
      remoteTimeoutMs: 1800,
    );
    expect(withRemote['remoteJsUrl'], 'https://example.com/bridge.js');
    expect(withRemote['remoteTimeoutMs'], 1800);

    final emptyRemote = HomeWebViewBridgeContract.buildInitConfig(
      remoteJsUrl: '   ',
    );
    expect(emptyRemote['remoteJsUrl'], isNull);
  });
}
