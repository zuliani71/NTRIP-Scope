import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/config.dart';
import 'package:ntripscope_mobile/geo.dart';
import 'package:ntripscope_mobile/map_view.dart';
import 'package:ntripscope_mobile/rover_angle_editor.dart';

void main() {
  test(
    'GGA map handles signed coordinates, height, priority, Stop and keyed station retention',
    () {
      final model = RoverMapModel();
      model.begin('caster|VRS', null);
      model.remember(const GeoPosition(45.51, 12.51, 120));
      model.accept(
        'Bluetooth',
        ascii.encode('${Rover(-45.5, -12.5, 100.123, 40.1).gga()}\r\n'),
      );
      final snapshot = model.snapshot;
      expect(snapshot.rover!.latitude, -45.5);
      expect(snapshot.rover!.longitude, -12.5);
      expect(snapshot.rover!.height, closeTo(100.123, 1e-6));
      model.stop();
      model.accept(
        'Bluetooth',
        ascii.encode('${Rover(46, 13, 5, 0).gga()}\r\n'),
      );
      expect(model.snapshot.rover, snapshot.rover);
      model.begin('caster|VRS', null);
      expect(model.snapshot.station, snapshot.station);
      expect(model.snapshot.lastKnown, isTrue);
      model.accept('TCP', ascii.encode('${Rover(46, 13, 5, 0).gga()}\r\n'));
      expect(model.snapshot.rover!.latitude, 46);
      model.begin('caster|VRS', const GeoPosition(44, 11, 10));
      model.accept(
        'Bluetooth',
        ascii.encode('${Rover(47, 14, 15, 0).gga()}\r\n'),
      );
      expect(model.snapshot.rover, const GeoPosition(44, 11, 10));
      model.begin('other caster|VRS', null);
      expect(model.snapshot.station, isNull);
      expect(
        const GeoPosition(0, 179.9).distanceKm(const GeoPosition(0, -179.9)),
        closeTo(22.239, 0.01),
      );
      expect(GeoPosition.dms(45.125, true), '45° 07′ 30.0000″ N');
      expect(GeoPosition.fromEcef(6378137, 0, 0)!.latitude, closeTo(0, 1e-8));
    },
  );
  testWidgets('manual decimal and DMS coordinates convert both ways', (
    tester,
  ) async {
    final decimal = TextEditingController(text: '45.123456');
    addTearDown(decimal.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RoverAngleEditor(
            decimal: decimal,
            latitude: true,
            enabled: true,
          ),
        ),
      ),
    );
    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, '45');
    expect(tester.widget<TextField>(fields.at(3)).controller!.text, '24.4416');
    await tester.enterText(fields.at(3), '30.0000');
    await tester.pump();
    expect(decimal.text, '45.125000');
    tester
        .widget<DropdownButton<bool>>(find.byType(DropdownButton<bool>))
        .onChanged!(true);
    await tester.pump();
    expect(decimal.text, '-45.125000');
  });
  testWidgets('rover movement preserves zoom until Show both is pressed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<ScopeMapState>();
    final positions = ValueNotifier(
      const GeoSnapshot(
        key: 'same',
        station: GeoPosition(45.5, 12.5),
        rover: GeoPosition(45.501, 12.501),
      ),
    );
    addTearDown(positions.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<GeoSnapshot>(
            valueListenable: positions,
            builder: (context, value, _) =>
                ScopeMap(key: key, snapshot: value, networkTiles: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    key.currentState!.zoomBy(-2);
    await tester.pumpAndSettle();
    final zoom = key.currentState!.currentZoom;
    positions.value = const GeoSnapshot(
      key: 'same',
      station: GeoPosition(45.5, 12.5),
      rover: GeoPosition(46, 13),
    );
    await tester.pumpAndSettle();
    expect(key.currentState!.currentZoom, closeTo(zoom, 1e-8));
    await tester.tap(find.text('Show both'));
    await tester.pumpAndSettle();
    expect(key.currentState!.currentZoom, isNot(closeTo(zoom, 0.01)));
    expect(find.textContaining('Distance from mountpoint:'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
