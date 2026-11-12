import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/geo.dart';
import 'package:ntripscope_mobile/map_view.dart';
import 'package:ntripscope_mobile/receiver_fix.dart';

void main() {
  testWidgets(
    'map identifies mountpoint and shows receiver fix separately from manual rover',
    (tester) async {
      tester.view.physicalSize = const Size(650, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> display(
        ReceiverFixStatus? fix, {
        bool active = true,
        bool rover = true,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ScopeMap(
                networkTiles: false,
                name: 'OGS_VRS',
                snapshot: GeoSnapshot(
                  station: const GeoPosition(45, 12, 100),
                  rover: rover ? const GeoPosition(45.01, 12, 120) : null,
                  source: 'Manual Rover position',
                ),
                fixStatus: fix,
                receiverActive: active,
                manualRover: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await display(ReceiverFixStatus(4, DateTime.now(), 'Bluetooth'));
      expect(find.textContaining('Mountpoint: OGS_VRS'), findsOneWidget);
      expect(find.textContaining('Receiver fix: RTK FIXED'), findsOneWidget);
      expect(find.textContaining('Manual GGA is sent'), findsOneWidget);
      await display(ReceiverFixStatus(5, DateTime.now(), 'Bluetooth'));
      expect(find.textContaining('Receiver fix: RTK FLOAT'), findsOneWidget);
      await display(
        ReceiverFixStatus(0, DateTime.now(), 'Bluetooth'),
        rover: false,
      );
      expect(find.textContaining('Receiver fix: NO FIX'), findsOneWidget);
      expect(find.text('Rover'), findsOneWidget);
      await display(
        ReceiverFixStatus(
          4,
          DateTime.now().subtract(const Duration(seconds: 10)),
          'Bluetooth',
        ),
      );
      expect(find.textContaining('STALE · RTK FIXED'), findsOneWidget);
      await display(
        ReceiverFixStatus(4, DateTime.now(), 'Bluetooth'),
        active: false,
      );
      expect(find.textContaining('PAUSED · RTK FIXED'), findsOneWidget);
      await display(null, rover: false);
      expect(find.textContaining('waiting for receiver GGA'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
