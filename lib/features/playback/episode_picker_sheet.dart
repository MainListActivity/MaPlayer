import 'package:flutter/material.dart';
import 'package:ma_palyer/features/playback/share_play_orchestrator.dart';

class EpisodePickerSheet extends StatefulWidget {
  const EpisodePickerSheet({
    super.key,
    required this.title,
    required this.episodes,
    this.preferredFileId,
  });

  final String title;
  final List<EpisodeCandidate> episodes;
  final String? preferredFileId;

  static Future<EpisodeCandidate?> show(
    BuildContext context, {
    required String title,
    required List<EpisodeCandidate> episodes,
    String? preferredFileId,
  }) {
    return showModalBottomSheet<EpisodeCandidate>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => EpisodePickerSheet(
        title: title,
        episodes: episodes,
        preferredFileId: preferredFileId,
      ),
    );
  }

  @override
  State<EpisodePickerSheet> createState() => _EpisodePickerSheetState();
}

class _EpisodePickerSheetState extends State<EpisodePickerSheet> {
  String? _selectedFileId;

  @override
  void initState() {
    super.initState();
    _selectedFileId = widget.preferredFileId;
    if (_selectedFileId == null) {
      for (final episode in widget.episodes) {
        if (episode.selectedByDefault) {
          _selectedFileId = episode.fileId;
          break;
        }
      }
    }
    _selectedFileId ??=
        widget.episodes.isEmpty ? null : widget.episodes.first.fileId;
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedFileId;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: widget.episodes.length,
                  itemBuilder: (context, index) {
                    final item = widget.episodes[index];
                    final active = item.fileId == selected;
                    return ListTile(
                      key: Key('episode-${item.fileId}'),
                      title: Text(item.name),
                      selected: active,
                      onTap: () {
                        setState(() {
                          _selectedFileId = item.fileId;
                        });
                      },
                      trailing: active ? const Icon(Icons.check_circle) : null,
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: selected == null
                      ? null
                      : () {
                          final episode = widget.episodes.firstWhere(
                            (e) => e.fileId == selected,
                          );
                          Navigator.of(context).pop(episode);
                        },
                  child: const Text('播放选中剧集'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
