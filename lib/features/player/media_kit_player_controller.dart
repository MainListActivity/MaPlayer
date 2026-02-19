import 'package:media_kit/media_kit.dart';

class MediaKitPlayerController {
  MediaKitPlayerController() : player = Player();

  final Player player;

  Future<void> open(String url, {Map<String, String>? headers}) async {
    final configuration = Media(
      url,
      httpHeaders: headers == null || headers.isEmpty ? null : headers,
    );
    await player.open(configuration);
  }

  Future<void> dispose() => player.dispose();
}
