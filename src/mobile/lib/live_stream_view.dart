import 'package:flutter/material.dart';
import 'rtcm.dart';

class LiveStreamsPanel extends StatefulWidget {
  const LiveStreamsPanel({
    super.key,
    required this.caster,
    required this.count,
    required this.receivers,
    required this.receiverCounts,
    required this.updates,
  });
  final List<int> caster;
  final int count;
  final Map<String, List<int>> receivers;
  final Map<String, int> receiverCounts;
  final Listenable updates;
  @override
  State<LiveStreamsPanel> createState() => _LiveStreamsPanelState();
}

class _LiveStreamsPanelState extends State<LiveStreamsPanel> {
  String? selected;
  Widget pane(String title, int count, String text, Color color) => Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 10, color: color),
              const SizedBox(width: 6),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('$count bytes', style: const TextStyle(fontSize: 11)),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.updates,
    builder: (context, _) {
      final keys = widget.receivers.keys.toList()..sort();
      final key = keys.contains(selected) ? selected : keys.firstOrNull;
      final data = widget.receivers[key] ?? const <int>[];
      final ascii = String.fromCharCodes(
        data.map((b) => b >= 32 && b < 127 || b == 10 || b == 13 ? b : 46),
      );
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Expanded(
              child: pane(
                'Caster → RTCM',
                widget.count,
                widget.caster.isEmpty
                    ? 'Waiting for data'
                    : hexAscii(widget.caster),
                Colors.green,
              ),
            ),
            if (keys.isNotEmpty)
              DropdownButton<String>(
                isExpanded: true,
                value: key,
                items: [
                  for (final source in keys)
                    DropdownMenuItem(value: source, child: Text(source)),
                ],
                onChanged: (value) => setState(() => selected = value),
              ),
            Expanded(
              flex: 2,
              child: pane(
                'Receiver → Client',
                widget.receiverCounts[key] ?? 0,
                data.isEmpty
                    ? 'Waiting for Bluetooth / serial / TCP data'
                    : 'ASCII\n$ascii\n\nHEX and ASCII · latest 256 bytes\n${hexAscii(data.length > 256 ? data.sublist(data.length - 256) : data)}',
                Colors.blue,
              ),
            ),
          ],
        ),
      );
    },
  );
}
