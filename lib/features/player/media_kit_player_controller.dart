import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

class MediaKitPlayerController {
  MediaKitPlayerController()
    : player = Player(
        configuration: PlayerConfiguration(
          bufferSize:
              defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS
              ? 32 * 1024 * 1024
              : 256 * 1024 * 1024,
        ),
      );

  final Player player;

  Future<void> open(String url, {Map<String, String>? headers}) async {
    debugPrint(
      '[MediaKitPlayerController] open url=$url headers=${headers?.length ?? 0}',
    );
    final configuration = Media(
      url,
      httpHeaders: (headers != null && headers.isNotEmpty) ? headers : null,
    );
    await player.open(configuration);
  }

  Future<void> dispose() => player.dispose();
}
