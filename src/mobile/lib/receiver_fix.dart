import 'dart:async';
import 'package:flutter/material.dart';
import 'gga.dart';

class ReceiverFixStatus {
  const ReceiverFixStatus(this.quality, this.received, this.source);
  final int quality;
  final DateTime received;
  final String source;
  String get label =>
      const {
        0: 'NO FIX',
        1: 'GNSS',
        2: 'DGNSS',
        4: 'RTK FIXED',
        5: 'RTK FLOAT',
        6: 'ESTIMATED',
      }[quality] ??
      'QUALITY $quality';
  int age(DateTime now) => now.difference(received).inSeconds.clamp(0, 1 << 31);
  bool stale(DateTime now) => age(now) > 5;
}

class ReceiverFixModel {
  final readers = <String, GgaReader>{};
  ReceiverFixStatus? status;
  void reset() {
    readers.clear();
    status = null;
  }

  bool add(String source, List<int> bytes, {DateTime? now}) {
    var changed = false;
    for (final sentence
        in readers
            .putIfAbsent(source, () => GgaReader(includeNoFix: true))
            .add(bytes)) {
      final quality = ggaQuality(sentence);
      if (quality != null) {
        status = ReceiverFixStatus(quality, now ?? DateTime.now(), source);
        changed = true;
      }
    }
    return changed;
  }
}

class ReceiverFixBadge extends StatefulWidget {
  const ReceiverFixBadge({
    super.key,
    required this.status,
    required this.active,
    required this.manual,
  });
  final ReceiverFixStatus? status;
  final bool active, manual;
  @override
  State<ReceiverFixBadge> createState() => _ReceiverFixBadgeState();
}

class _ReceiverFixBadgeState extends State<ReceiverFixBadge> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status, now = DateTime.now();
    final stale = status?.stale(now) ?? false;
    final prefix = !widget.active
        ? 'PAUSED · '
        : stale
        ? 'STALE · '
        : '';
    final color = status == null || prefix.isNotEmpty
        ? Colors.grey.shade700
        : status.quality == 0
        ? Colors.red.shade800
        : status.quality == 4
        ? Colors.green.shade800
        : Colors.orange.shade900;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.gps_fixed, color: color, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  status == null
                      ? 'Receiver fix: waiting for receiver GGA'
                      : 'Receiver fix: $prefix${status.label} · ${status.age(now)} s · ${status.source}',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          if (widget.manual)
            const Text(
              'Manual GGA is sent to the caster; receiver fix is shown separately.',
              style: TextStyle(fontSize: 11),
            ),
        ],
      ),
    );
  }
}
