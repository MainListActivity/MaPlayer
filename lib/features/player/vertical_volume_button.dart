import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Helper to access the VideoController from context,
// mirroring the approach used by media_kit_video's built-in buttons.
VideoController _controller(BuildContext context) =>
    VideoStateInheritedWidget.of(context).state.widget.controller;

class VerticalVolumeButton extends StatefulWidget {
  final double iconSize;

  const VerticalVolumeButton({super.key, this.iconSize = 24.0});

  @override
  State<VerticalVolumeButton> createState() => _VerticalVolumeButtonState();
}

class _VerticalVolumeButtonState extends State<VerticalVolumeButton> {
  late double volume;
  bool mute = false;
  double _savedVolume = 0.0;
  bool hover = false;
  StreamSubscription<double>? _subscription;

  @override
  void setState(VoidCallback fn) {
    if (mounted) super.setState(fn);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = _controller(context).player;
    volume = player.state.volume;
    _subscription ??= player.stream.volume.listen((v) {
      setState(() => volume = v);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Player get _player => _controller(context).player;

  @override
  Widget build(BuildContext context) {
    const double panelHeight = 110.0;
    const double panelWidth = 32.0;
    const double buttonHeight = 48.0;
    const double gap = 4.0;

    return MouseRegion(
      onEnter: (_) => setState(() => hover = true),
      onExit: (_) => setState(() => hover = false),
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final newVol = event.scrollDelta.dy < 0
                ? (volume + 5.0).clamp(0.0, 100.0)
                : (volume - 5.0).clamp(0.0, 100.0);
            _player.setVolume(newVol);
          }
        },
        // Fixed layout height matching other bar buttons — no alignment disruption.
        child: SizedBox(
          width: panelWidth + 16,
          height: buttonHeight,
          child: Stack(
            // Allow popup to paint outside bounds upward without affecting layout.
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // ─── Popup slider panel (overflows upward, no layout effect) ───
              Positioned(
                bottom: buttonHeight + gap,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: hover ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: hover ? panelHeight : 0,
                    width: panelWidth,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D1219).withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFF2E3B56)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 2.0,
                              inactiveTrackColor: const Color(0xFF2E3B56),
                              activeTrackColor: Colors.white,
                              thumbColor: Colors.white,
                              overlayColor: Colors.white.withValues(alpha: 0.1),
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5.0,
                                elevation: 0.0,
                                pressedElevation: 0.0,
                              ),
                            ),
                            child: Slider(
                              value: volume.clamp(0.0, 100.0),
                              min: 0.0,
                              max: 100.0,
                              onChanged: (v) async {
                                await _player.setVolume(v);
                                mute = false;
                                setState(() {});
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ─── Volume icon button (centered in fixed 48px height) ───
              IconButton(
                onPressed: () async {
                  if (mute) {
                    await _player.setVolume(_savedVolume);
                    setState(() => mute = false);
                  } else if (volume == 0.0) {
                    _savedVolume = 100.0;
                    await _player.setVolume(100.0);
                    setState(() => mute = false);
                  } else {
                    _savedVolume = volume;
                    await _player.setVolume(0.0);
                    setState(() => mute = true);
                  }
                },
                iconSize: widget.iconSize,
                color: Colors.white,
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: (volume == 0.0 || mute)
                      ? const Icon(Icons.volume_off, key: ValueKey('off'))
                      : volume < 50.0
                      ? const Icon(Icons.volume_down, key: ValueKey('down'))
                      : const Icon(Icons.volume_up, key: ValueKey('up')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
