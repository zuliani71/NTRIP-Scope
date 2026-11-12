import 'package:flutter/material.dart';

class TrafficBar extends StatefulWidget {
  const TrafficBar({super.key, required this.active, this.lastData});
  final bool active;
  final DateTime? lastData;
  @override
  State<TrafficBar> createState() => _TrafficBarState();
}

class _TrafficBarState extends State<TrafficBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1560),
  );
  @override
  void initState() {
    super.initState();
    if (widget.active) animation.repeat();
  }

  @override
  void didUpdateWidget(covariant TrafficBar old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      animation.repeat();
    } else if (!widget.active) {
      animation.stop();
      animation.value = 0;
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final recent =
          widget.active &&
          widget.lastData != null &&
          DateTime.now().difference(widget.lastData!).inMilliseconds < 2500;
      final lit = recent ? (animation.value * 13).floor() : 0;
      return Semantics(
        label: recent ? 'Receiving data' : 'No recent data',
        child: SizedBox(
          height: 8,
          child: Row(
            children: [
              for (var i = 0; i < 12; i++)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    color: i < lit ? Colors.green : Colors.grey.shade300,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
