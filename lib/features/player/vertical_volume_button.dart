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
  static const double _panelHeight = 110.0;
  static const double _panelWidth = 32.0;
  static const double _buttonHeight = 48.0;
  static const double _gap = 4.0;
  static const Duration _hideDelay = Duration(milliseconds: 120);

  late double volume;
  bool mute = false;
  double _savedVolume = 0.0;
  StreamSubscription<double>? _subscription;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  Timer? _hideTimer;
  bool _buttonHover = false;
  bool _panelHover = false;

  @override
  void setState(VoidCallback fn) {
    if (!mounted) return;
    super.setState(fn);
    _overlayEntry?.markNeedsBuild();
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
    _hideTimer?.cancel();
    _removeOverlay();
    _subscription?.cancel();
    super.dispose();
  }

  Player get _player => _controller(context).player;
  bool get _isHovering => _buttonHover || _panelHover;

  void _showOverlay() {
    _hideTimer?.cancel();
    if (_overlayEntry == null) {
      _overlayEntry = OverlayEntry(builder: (_) => _buildOverlayPanel());
      Overlay.of(context, rootOverlay: true).insert(_overlayEntry!);
      return;
    }
    _overlayEntry?.markNeedsBuild();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _scheduleHideOverlay() {
    _hideTimer?.cancel();
    if (_isHovering) return;
    _hideTimer = Timer(_hideDelay, () {
      if (!_isHovering) {
        _removeOverlay();
      }
    });
  }

  Widget _buildOverlayPanel() {
    return Positioned.fill(
      child: Stack(
        children: [
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topCenter,
            followerAnchor: Alignment.bottomCenter,
            offset: const Offset(0, -_gap),
            child: MouseRegion(
              onEnter: (_) {
                _panelHover = true;
                _hideTimer?.cancel();
              },
              onExit: (_) {
                _panelHover = false;
                _scheduleHideOverlay();
              },
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: _panelWidth,
                  height: _panelHeight,
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
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        _buttonHover = true;
        _showOverlay();
      },
      onExit: (_) {
        _buttonHover = false;
        _scheduleHideOverlay();
      },
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final newVol = event.scrollDelta.dy < 0
                ? (volume + 5.0).clamp(0.0, 100.0)
                : (volume - 5.0).clamp(0.0, 100.0);
            _player.setVolume(newVol);
          }
        },
        child: SizedBox(
          width: _panelWidth + 16,
          height: _buttonHeight,
          child: CompositedTransformTarget(
            link: _layerLink,
            child: IconButton(
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
          ),
        ),
      ),
    );
  }
}
