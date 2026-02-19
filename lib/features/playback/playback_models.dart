import 'package:ma_palyer/features/cloud/quark/quark_models.dart';

class PlaybackRequest {
  const PlaybackRequest({
    required this.sourceKey,
    required this.playFlag,
    required this.episodeUrl,
    this.subtitleKey,
    this.progressKey,
  });

  final String sourceKey;
  final String playFlag;
  final String episodeUrl;
  final String? subtitleKey;
  final String? progressKey;
}

class PlayableMedia {
  const PlayableMedia({
    required this.url,
    required this.headers,
    required this.subtitle,
    required this.progressKey,
  });

  final String url;
  final Map<String, String> headers;
  final String? subtitle;
  final String progressKey;
}

class PlaybackResolveResult {
  const PlaybackResolveResult({
    required this.media,
    required this.rawPlayerContent,
  });

  final PlayableMedia media;
  final Map<String, dynamic> rawPlayerContent;
}

class QuarkLoginChallenge {
  const QuarkLoginChallenge({required this.session});

  final QuarkQrSession session;
}

class PlaybackException implements Exception {
  PlaybackException(this.message, {this.code, this.raw});

  final String message;
  final String? code;
  final Object? raw;

  @override
  String toString() => 'PlaybackException($code): $message';
}
