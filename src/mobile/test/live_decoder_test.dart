import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/main.dart';
import 'package:ntripscope_mobile/rtcm.dart';
import 'package:ntripscope_mobile/cnr_chart.dart';

RtcmFrame msm(int code, int cnr) {
  final fields = [
    (1074, 12),
    (17, 12),
    (1234, 30),
    (0, 19),
    for (var i = 1; i <= 64; i++) (i == 6 ? 1 : 0, 1),
    for (var i = 1; i <= 32; i++) (i == 2 ? 1 : 0, 1),
    (1, 1),
    (80, 8),
    (512, 10),
    (code, 15),
    (0, 22),
    (0, 5),
    (cnr, 6),
  ];
  final bits = [
    for (final (value, width) in fields)
      for (var i = width - 1; i >= 0; i--) (value >> i) & 1,
  ];
  while (bits.length % 8 != 0) {
    bits.add(0);
  }
  return RtcmFrame([
    for (var i = 0; i < bits.length; i += 8)
      bits.getRange(i, i + 8).fold(0, (value, bit) => (value << 1) | bit),
  ]);
}

void main() {
  testWidgets(
    'live pseudorange and C/N0 update, historical selection and chart stay pinned',
    (tester) async {
      final first = msm(0, 42), frames = [msm(0, 42)];
      frames[0] = first;
      final revision = ValueNotifier(0);
      addTearDown(revision.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: FrameView(frames: frames, updates: revision),
        ),
      );
      expect(find.text('42.0000'), findsOneWidget);
      final second = msm(100, 43);
      frames.insert(0, second);
      revision.value++;
      await tester.pump();
      expect(find.text('43.0000'), findsOneWidget);
      expect(
        find.text(second.observations().single.code!.toStringAsFixed(4)),
        findsOneWidget,
      );
      final dropdown = find.byType(DropdownButton<Object>);
      tester.widget<DropdownButton<Object>>(dropdown).onChanged!(first);
      await tester.pump();
      frames
        ..clear()
        ..add(msm(200, 44));
      revision.value++;
      await tester.pump();
      expect(find.text('42.0000'), findsOneWidget);
      final graph = find.text('C/N₀ chart');
      await tester.ensureVisible(graph);
      await tester.tap(graph);
      await tester.pump();
      expect(
        tester.widget<CnrChart>(find.byType(CnrChart)).rows.single.cnr,
        42,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
