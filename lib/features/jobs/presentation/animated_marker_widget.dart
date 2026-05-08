import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'dart:math' as math;

class AnimatedMarkerWidget extends StatefulWidget {
  final LatLng position;
  final LatLng? previous;
  final double? speed;
  final Widget Function(LatLng pos, double bearing) builder;

  const AnimatedMarkerWidget({
    super.key,
    required this.position,
    required this.previous,
    required this.builder,
    this.speed,
  });

  @override
  State<AnimatedMarkerWidget> createState() =>
      _AnimatedMarkerWidgetState();
}

class _AnimatedMarkerWidgetState extends State<AnimatedMarkerWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  LatLng? _from;
  LatLng? _to;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    _setup(first: true);
  }

  @override
  void didUpdateWidget(covariant AnimatedMarkerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.position != oldWidget.position) {
      _setup();
    }
  }

  void _setup({bool first = false}) {
    _from = widget.previous ?? widget.position;
    _to = widget.position;

    final speed = (widget.speed ?? 5).clamp(1, 15);
    final durationMs = (1400 / speed).clamp(250, 900).toInt();
    _controller.duration = Duration(milliseconds: durationMs);

    if (first) {
      _controller.value = 1.0;
    } else {
      // Newly added: reuse the same controller so marker updates do not leak
      // ticker instances across rebuilds.
      _controller.forward(from: 0);
    }
  }

  LatLng _lerp() {
    final t = _animation.value;

    return LatLng(
      _from!.latitude + (_to!.latitude - _from!.latitude) * t,
      _from!.longitude + (_to!.longitude - _from!.longitude) * t,
    );
  }

  double _bearing() {
    final lat1 = _from!.latitude * math.pi / 180;
    final lat2 = _to!.latitude * math.pi / 180;
    final dLon = (_to!.longitude - _from!.longitude) * math.pi / 180;

    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);

    return math.atan2(y, x);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (_, __) {
        final pos = _lerp();
        final bearing = _bearing();
        return widget.builder(pos, bearing);
      },
    );
  }
}
