import 'package:ma_palyer/features/cloud/quark/quark_models.dart';
import 'package:ma_palyer/features/player/proxy/proxy_models.dart';

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
    this.variants = const <QuarkPlayableVariant>[],
    this.selectedVariant,
  });

  final String url;
  final Map<String, String> headers;
  final String? subtitle;
  final String progressKey;
  final List<QuarkPlayableVariant> variants;
  final QuarkPlayableVariant? selectedVariant;
}

class PlaybackResolveResult {
  const PlaybackResolveResult({
    required this.media,
    required this.rawPlayerContent,
  });

  final PlayableMedia media;
  final Map<String, dynamic> rawPlayerContent;
}

class ResolvedPlaybackEndpoint {
  const ResolvedPlaybackEndpoint({
    required this.originalMedia,
    required this.playbackUrl,
    this.proxySession,
  });

  final PlayableMedia originalMedia;
  final String playbackUrl;
  final ProxySessionDescriptor? proxySession;
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
