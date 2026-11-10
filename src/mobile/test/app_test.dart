import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/main.dart';
import 'package:ntripscope_mobile/rtcm.dart';

void main() {
  testWidgets('phone layout has diagnostics tabs and caster form', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ScopeApp());
    await tester.pumpAndSettle();
    expect(find.text('Load configuration'), findsOneWidget);
    expect(find.text('Caster host'), findsOneWidget);
    await tester.tap(find.text('Live stream'));
    await tester.pumpAndSettle();
    expect(find.text('Latest bytes · HEX and ASCII'), findsOneWidget);
    await tester.tap(find.text('RTCM3'));
    await tester.pumpAndSettle();
    expect(find.text('No valid RTCM3 frames received'), findsOneWidget);
  });
  testWidgets('latest RTCM frame follows the stream and history stays pinned', (
    tester,
  ) async {
    RtcmFrame frame(int station) =>
        RtcmFrame([0x3e, 0xd0, station, ...List.filled(16, 0)]);
    final first = frame(17);
    final frames = [first];
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: FrameView(frames: frames, updates: revision),
      ),
    );
    expect(find.text('Station · 17'), findsOneWidget);

    frames.insert(0, frame(18));
    revision.value++;
    await tester.pump();
    expect(find.text('Station · 18'), findsOneWidget);

    final dropdown = find.byType(DropdownButton<Object>);
    tester.widget<DropdownButton<Object>>(dropdown).onChanged!(first);
    await tester.pump();
    frames.remove(first);
    frames.insert(0, frame(19));
    revision.value++;
    await tester.pump();
    expect(find.text('Station · 17'), findsOneWidget);

    tester.widget<DropdownButton<Object>>(dropdown).onChanged!(
      tester.widget<DropdownButton<Object>>(dropdown).items!.first.value,
    );
    await tester.pump();
    expect(find.text('Station · 19'), findsOneWidget);
  });
}
