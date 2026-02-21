import 'package:ma_palyer/features/cloud/quark/quark_models.dart';

class ParsedMediaInfo {
  ParsedMediaInfo({
    required this.file,
    this.season,
    this.episode,
    this.resolution,
    this.framerate,
    this.hdrFormat,
    this.codec,
    this.audioCodec,
  });

  final QuarkShareFileEntry file;
  final int? season;
  final int? episode;
  final String? resolution;
  final String? framerate;
  final String? hdrFormat;
  final String? codec;
  final String? audioCodec;

  String get id => file.fid;
  String get name => file.fileName;

  String get displayTitle {
    if (season != null && episode != null) {
      return 'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    } else if (episode != null) {
      return 'EP${episode.toString().padLeft(2, '0')}';
    }
    return name;
  }

  String get displayResolution {
    final parts = <String>[];
    if (resolution != null) parts.add(resolution!);
    if (framerate != null) parts.add(framerate!);
    if (hdrFormat != null) parts.add(hdrFormat!);
    if (parts.isEmpty) {
      return 'Default';
    }
    return parts.join(' ');
  }

  String get groupKey {
    if (season != null && episode != null) {
      return '$season-$episode';
    } else if (episode != null) {
      return 'null-$episode';
    } else {
      var baseName = name;
      final tagsToRemove = [
        resolution,
        framerate,
        hdrFormat,
        codec,
        audioCodec,
      ].whereType<String>();
      for (final tag in tagsToRemove) {
        baseName = baseName.replaceAll(RegExp(tag, caseSensitive: false), '');
      }
      return baseName.trim();
    }
  }
}

class MediaFileParser {
  static final _seasonEpisodeRegex = RegExp(
    r'S(\d+)E(\d+)',
    caseSensitive: false,
  );
  static final _episodeOnlyRegex = RegExp(r'EP?(\d+)', caseSensitive: false);
  static final _resolutionRegex = RegExp(
    r'(2160p|1080p|720p|4k)',
    caseSensitive: false,
  );
  static final _framerateRegex = RegExp(r'(\d{2}fps)', caseSensitive: false);
  static final _hdrRegex = RegExp(
    r'(HDR10\+|HDR10|HDR|DV|Dolby Vision)',
    caseSensitive: false,
  );
  static final _codecRegex = RegExp(
    r'(H\.?265|H\.?264|HEVC|AVC|x265|x264)',
    caseSensitive: false,
  );
  static final _audioRegex = RegExp(
    r'(FLAC|AAC|EAC3|AC3|Atmos|DTS-HD|DTS)',
    caseSensitive: false,
  );

  static ParsedMediaInfo parse(QuarkShareFileEntry file) {
    final name = file.fileName;

    int? season;
    int? episode;

    final seMatch = _seasonEpisodeRegex.firstMatch(name);
    if (seMatch != null) {
      season = int.tryParse(seMatch.group(1)!);
      episode = int.tryParse(seMatch.group(2)!);
    } else {
      final epMatch = _episodeOnlyRegex.firstMatch(name);
      if (epMatch != null) {
        episode = int.tryParse(epMatch.group(1)!);
      } else {
        // Fallback: search for numbers surrounded by dots or spaces often used for episodes
        final fbMatch = RegExp(r'[. ](\d{1,3})[. ]').firstMatch(name);
        if (fbMatch != null && fbMatch.group(1) != null) {
          // Careful with years, e.g. .2024., so check length
          if (fbMatch.group(1)!.length < 4) {
            episode = int.tryParse(fbMatch.group(1)!);
          }
        } else {
          // Chinese parts: 上/中/下
          final zhMatch = RegExp(r'(?:剧场版)?[\s_-]*([上中下])').firstMatch(name);
          if (zhMatch != null) {
            final val = zhMatch.group(1)!;
            if (val == '上') episode = 1;
            if (val == '中') episode = 2;
            if (val == '下') episode = 3;
          }
        }
      }
    }

    final resMatch = _resolutionRegex.firstMatch(name);
    final fpsMatch = _framerateRegex.firstMatch(name);
    final hdrMatch = _hdrRegex.firstMatch(name);
    final codecMatch = _codecRegex.firstMatch(name);
    final audioMatch = _audioRegex.firstMatch(name);

    return ParsedMediaInfo(
      file: file,
      season: season,
      episode: episode,
      resolution: resMatch?.group(1),
      framerate: fpsMatch?.group(1),
      hdrFormat: hdrMatch?.group(1),
      codec: codecMatch?.group(1),
      audioCodec: audioMatch?.group(1),
    );
  }
}
