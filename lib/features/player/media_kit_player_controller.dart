import 'package:media_kit/media_kit.dart';

class MediaKitPlayerController {
  MediaKitPlayerController()
    : player = Player(
        configuration: const PlayerConfiguration(
          // Increase demuxer cache for large raw files to reduce stutter under
          // short-term network jitter.
          bufferSize: 256 * 1024 * 1024,
        ),
      );

  final Player player;

  Future<void> open(String url, {Map<String, String>? headers}) async {
    final configuration = Media(
      url,
      httpHeaders: (headers != null && headers.isNotEmpty) ? headers : null,
    );
    await player.open(configuration);
  }

  Future<void> dispose() => player.dispose();
}
