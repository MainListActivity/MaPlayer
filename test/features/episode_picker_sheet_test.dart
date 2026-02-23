import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ma_palyer/features/playback/episode_picker_sheet.dart';
import 'package:ma_palyer/features/playback/share_play_orchestrator.dart';

void main() {
  testWidgets('default episode highlighted and confirm returns selection', (
    WidgetTester tester,
  ) async {
    EpisodeCandidate? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    selected = await EpisodePickerSheet.show(
                      context,
                      title: '测试剧',
                      episodes: const <EpisodeCandidate>[
                        EpisodeCandidate(
                          fileId: 'e1',
                          name: '第1集',
                          selectedByDefault: false,
                        ),
                        EpisodeCandidate(
                          fileId: 'e2',
                          name: '第2集',
                          selectedByDefault: true,
                        ),
                      ],
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('episode-e1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放选中剧集'));
    await tester.pumpAndSettle();

    expect(selected?.fileId, 'e1');
  });
}
