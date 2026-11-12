import 'package:flutter/material.dart';

class RoverAngleEditor extends StatefulWidget {
  const RoverAngleEditor({
    super.key,
    required this.decimal,
    required this.latitude,
    required this.enabled,
  });
  final TextEditingController decimal;
  final bool latitude, enabled;
  @override
  State<RoverAngleEditor> createState() => _RoverAngleEditorState();
}

class _RoverAngleEditorState extends State<RoverAngleEditor> {
  final degrees = TextEditingController(),
      minutes = TextEditingController(),
      seconds = TextEditingController();
  bool negative = false, updating = false;
  double? number(String s) => double.tryParse(s.replaceAll(',', '.'));
  @override
  void initState() {
    super.initState();
    widget.decimal.addListener(fromDecimal);
    fromDecimal();
  }

  void fromDecimal() {
    if (updating) return;
    final value = number(widget.decimal.text),
        limit = widget.latitude ? 90 : 180;
    if (value == null || !value.isFinite || value.abs() > limit) return;
    updating = true;
    negative = value.isNegative;
    final units = (value.abs() * 36000000).round();
    degrees.text = '${units ~/ 36000000}';
    minutes.text = '${units ~/ 600000 % 60}';
    seconds.text = (units % 600000 / 10000).toStringAsFixed(4);
    updating = false;
    if (mounted) setState(() {});
  }

  void fromDms() {
    if (updating) return;
    final d = number(degrees.text),
        m = number(minutes.text),
        s = number(seconds.text),
        limit = widget.latitude ? 90 : 180;
    if (d == null ||
        m == null ||
        s == null ||
        d != d.floorToDouble() ||
        m != m.floorToDouble() ||
        d < 0 ||
        m < 0 ||
        m >= 60 ||
        s < 0 ||
        s >= 60)
      return;
    final value = (d + m / 60 + s / 3600) * (negative ? -1 : 1);
    if (!value.isFinite || value.abs() > limit) return;
    updating = true;
    widget.decimal.text = value.toStringAsFixed(6);
    updating = false;
  }

  void normalize() {
    final value = number(widget.decimal.text);
    if (value != null &&
        value.isFinite &&
        value.abs() <= (widget.latitude ? 90 : 180))
      widget.decimal.text = value.toStringAsFixed(6);
    fromDecimal();
  }

  @override
  void dispose() {
    widget.decimal.removeListener(fromDecimal);
    degrees.dispose();
    minutes.dispose();
    seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Focus(
        onFocusChange: (focused) {
          if (!focused) normalize();
        },
        child: TextField(
          controller: widget.decimal,
          enabled: widget.enabled,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText:
                '${widget.latitude ? 'Latitude' : 'Longitude'} · decimal degrees',
          ),
        ),
      ),
      Row(
        children: [
          for (final (controller, label) in [
            (degrees, 'Degrees'),
            (minutes, 'Minutes'),
            (seconds, 'Seconds'),
          ])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Focus(
                  onFocusChange: (focused) {
                    if (!focused) normalize();
                  },
                  child: TextField(
                    controller: controller,
                    enabled: widget.enabled,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(labelText: label),
                    onChanged: (_) => fromDms(),
                  ),
                ),
              ),
            ),
          DropdownButton<bool>(
            value: negative,
            items: [
              DropdownMenuItem(
                value: false,
                child: Text(widget.latitude ? 'N' : 'E'),
              ),
              DropdownMenuItem(
                value: true,
                child: Text(widget.latitude ? 'S' : 'W'),
              ),
            ],
            onChanged: widget.enabled
                ? (value) {
                    setState(() => negative = value!);
                    fromDms();
                  }
                : null,
          ),
        ],
      ),
      const SizedBox(height: 8),
    ],
  );
}
