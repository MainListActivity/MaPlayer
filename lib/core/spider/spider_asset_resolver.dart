import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:ma_palyer/core/spider/spider_engine.dart';
import 'package:ma_palyer/network/http_headers.dart';
import 'package:ma_palyer/tvbox/tvbox_models.dart';

class SpiderAssetResolver {
  SpiderAssetResolver({this.cacheDirName = '.spider_cache', this.logger});

  final String cacheDirName;
  final SpiderTraceLogger? logger;

  Future<SpiderRuntimeSite> resolveRuntimeSite({
    required TvBoxSite site,
    required String sourceKey,
    String? globalSpider,
  }) async {
    final engine = detectEngineFromSite(site, globalSpider: globalSpider);
    final api = (site.api ?? '').trim();
    final jar = _pickJar(site.jar, globalSpider);
    final resolvedApi = switch (engine) {
      SpiderEngineType.js ||
      SpiderEngineType.py => await _resolveScriptPath(api, kind: 'api'),
      SpiderEngineType.jar => api,
    };
    final resolvedJar = switch (engine) {
      SpiderEngineType.jar => await _resolveAssetPath(jar, kind: 'jar'),
      SpiderEngineType.js || SpiderEngineType.py => jar,
    };
    final resolvedExt = _resolveExt(site.ext);

    return SpiderRuntimeSite(
      sourceKey: sourceKey,
      api: resolvedApi,
      ext: resolvedExt,
      jar: resolvedJar,
    );
  }

  String _pickJar(String? siteJar, String? globalSpider) {
    final local = siteJar?.trim() ?? '';
    if (local.isNotEmpty) return local;
    return globalSpider?.trim() ?? '';
  }

  String _resolveExt(dynamic ext) {
    if (ext is! String) return ext?.toString() ?? '';
    return ext.trim();
  }

  Future<String> _resolveAssetPath(String raw, {required String kind}) async {
    if (raw.isEmpty) return raw;
    final descriptor = _parseDescriptor(raw);
    final uri = Uri.tryParse(descriptor.url);
    if (uri == null || !uri.hasScheme) return raw;
    if (uri.scheme != 'http' && uri.scheme != 'https') return raw;

    final localFile = await _downloadToCache(
      uri,
      kind: kind,
      expectedMd5: descriptor.expectedMd5,
    );
    return localFile.path;
  }

  Future<String> _resolveScriptPath(String raw, {required String kind}) async {
    if (raw.isEmpty) return raw;
    if (!_looksLikeScript(raw)) return raw;
    return _resolveAssetPath(raw, kind: kind);
  }

  Future<File> _downloadToCache(
    Uri uri, {
    required String kind,
    String? expectedMd5,
  }) async {
    final dir = Directory('${Directory.current.path}/$cacheDirName');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final pathHash = sha1.convert(uri.toString().codeUnits).toString();
    final ext = _extFromUri(uri);
    final file = File('${dir.path}/$kind-$pathHash$ext');
    if (file.existsSync() && file.lengthSync() > 0) {
      if (expectedMd5 != null) {
        final digest = await _fileMd5(file);
        if (digest.toLowerCase() == expectedMd5.toLowerCase()) {
          logger?.call(
            'Spider asset cache hit (md5 ok): ${uri.toString()} -> ${file.path}',
          );
          return file;
        }
        logger?.call(
          'Spider asset cache stale (md5 mismatch), re-download: ${uri.toString()}',
        );
      } else {
        logger?.call(
          'Spider asset cache hit: ${uri.toString()} -> ${file.path}',
        );
        return file;
      }
    }

    logger?.call('Spider asset downloading: ${uri.toString()}');
    final resp = await http.get(uri, headers: kDefaultHttpHeaders);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SpiderRuntimeException(
        'Download spider asset failed: HTTP ${resp.statusCode}',
        code: 'ASSET_DOWNLOAD_FAILED',
        detail: uri.toString(),
      );
    }
    await file.writeAsBytes(resp.bodyBytes, flush: true);
    if (expectedMd5 != null) {
      final digest = await _fileMd5(file);
      if (digest.toLowerCase() != expectedMd5.toLowerCase()) {
        throw SpiderRuntimeException(
          'Spider asset md5 mismatch',
          code: 'ASSET_MD5_MISMATCH',
          detail:
              'url=${uri.toString()} expected=$expectedMd5 actual=$digest path=${file.path}',
        );
      }
    }
    return file;
  }

  Future<String> _fileMd5(File file) async {
    final bytes = await file.readAsBytes();
    return md5.convert(bytes).toString();
  }

  String _extFromUri(Uri uri) {
    final segs = uri.pathSegments;
    if (segs.isEmpty) return '';
    final last = segs.last;
    final idx = last.lastIndexOf('.');
    if (idx <= 0 || idx >= last.length - 1) return '';
    final ext = last.substring(idx);
    if (ext.length > 8) return '';
    return RegExp(r'^[.a-zA-Z0-9_-]+$').hasMatch(ext) ? ext : '';
  }

  bool _looksLikeScript(String raw) {
    final descriptor = _parseDescriptor(raw);
    final uri = Uri.tryParse(descriptor.url);
    final path = (uri?.path ?? descriptor.url).toLowerCase();
    return path.endsWith('.js') || path.endsWith('.py');
  }

  _SpiderAssetDescriptor _parseDescriptor(String raw) {
    final input = raw.trim();
    final parts = input.split(';');
    if (parts.length >= 3 && parts[1].trim().toLowerCase() == 'md5') {
      final url = parts[0].trim();
      final digest = parts[2].trim();
      if (url.isNotEmpty && digest.isNotEmpty) {
        return _SpiderAssetDescriptor(url: url, expectedMd5: digest);
      }
    }
    return _SpiderAssetDescriptor(url: input, expectedMd5: null);
  }
}

class _SpiderAssetDescriptor {
  const _SpiderAssetDescriptor({required this.url, required this.expectedMd5});

  final String url;
  final String? expectedMd5;
}
