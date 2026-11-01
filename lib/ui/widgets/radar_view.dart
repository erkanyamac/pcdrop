import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/device.dart';

class RadarView extends StatefulWidget {
  const RadarView({
    required this.devices,
    required this.onDeviceTap,
    super.key,
  });

  final List<Device> devices;
  final ValueChanged<Device> onDeviceTap;

  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: _RadarPainter(progress: _controller.value),
            child: Stack(
              children: [
                const Center(
                  child: CircleAvatar(
                    radius: 34,
                    child: Icon(Icons.wifi_tethering, size: 32),
                  ),
                ),
                ...widget.devices.asMap().entries.map((entry) {
                  final angle =
                      entry.key *
                      (2 * math.pi / math.max(widget.devices.length, 1));
                  return Align(
                    alignment: Alignment(
                      math.cos(angle) * 0.62,
                      math.sin(angle) * 0.62,
                    ),
                    child: _DeviceBubble(
                      device: entry.value,
                      onTap: () => widget.onDeviceTap(entry.value),
                    ),
                  );
                }),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DeviceBubble extends StatelessWidget {
  const _DeviceBubble({required this.device, required this.onTap});

  final Device device;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = device.os == DeviceOperatingSystem.windows
        ? Icons.desktop_windows
        : Icons.tablet_mac;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(48),
      child: SizedBox(
        width: 96,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 27,
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              child: Icon(icon),
            ),
            const SizedBox(height: 4),
            Text(
              device.alias,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  const _RadarPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final ringPaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (var index = 1; index <= 3; index++) {
      canvas.drawCircle(center, radius * index / 3, ringPaint);
    }
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.blue.withValues(alpha: 0.35),
          Colors.blue.withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      progress * 2 * math.pi,
      math.pi / 2,
      true,
      sweepPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
