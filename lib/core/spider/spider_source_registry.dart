import 'package:ma_palyer/tvbox/tvbox_config_repository.dart';
import 'package:ma_palyer/tvbox/tvbox_models.dart';
import 'package:ma_palyer/tvbox/tvbox_parser.dart';

class SpiderSourceRegistry {
  SpiderSourceRegistry({TvBoxConfigRepository? repository, TvBoxParser? parser})
    : _repository = repository ?? TvBoxConfigRepository(),
      _parser = parser ?? TvBoxParser();

  final TvBoxConfigRepository _repository;
  final TvBoxParser _parser;

  TvBoxConfig? _cached;

  Future<TvBoxConfig> loadConfig({bool forceRefresh = false}) async {
    if (!forceRefresh && _cached != null) {
      return _cached!;
    }
    final draft = await _repository.loadDraft();
    final config = await _parser.parseStringOrThrow(
      draft.rawJson,
      baseUri: Uri.tryParse(draft.sourceUrl),
    );
    _cached = config;
    return config;
  }

  Future<TvBoxSite?> findSite(String sourceKey) async {
    final config = await loadConfig();
    for (final site in config.sites) {
      if (site.key == sourceKey) return site;
    }
    return null;
  }

  Future<List<String>> vipFlags() async {
    final config = await loadConfig();
    return config.flags;
  }
}
