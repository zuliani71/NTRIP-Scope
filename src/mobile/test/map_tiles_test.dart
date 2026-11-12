import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/geo.dart';
import 'package:ntripscope_mobile/map_view.dart';

class LocalTiles extends TileProvider {
  final requested = <TileCoordinates>{};
  final image = MemoryImage(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNYcOABAAREAkHnHWtmAAAAAElFTkSuQmCC',
    ),
  );
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    requested.add(coordinates);
    return image;
  }
}

void checkVisibleTiles(WidgetTester tester, LocalTiles provider) {
  final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
  final camera = map.mapController!.camera;
  final z = camera.zoom.round();
  final centre = camera.projectAtZoom(camera.center, z.toDouble());
  final scale = math.pow(2, camera.zoom - z);
  final half = camera.size / (scale * 2);
  final left = ((centre.dx.floor() - half.width) / 256).floor();
  final right = ((centre.dx.floor() + half.width) / 256).ceil() - 1;
  final top = ((centre.dy.floor() - half.height) / 256).floor();
  final bottom = ((centre.dy.floor() + half.height) / 256).ceil() - 1;

  for (var x = left; x <= right; x++) {
    for (var y = top; y <= bottom; y++) {
      final coordinate = TileCoordinates(x, y, z);
      expect(
        provider.requested,
        contains(coordinate),
        reason: 'Visible tile $coordinate must load without a pan/zoom',
      );
    }
  }
  final mapRect = tester.getRect(find.byType(FlutterMap));
  final painted = find
      .descendant(of: find.byType(FlutterMap), matching: find.byType(RawImage))
      .evaluate()
      .where((e) => (e.widget as RawImage).image != null)
      .map((e) => tester.getRect(find.byWidget(e.widget)))
      .toList();
  for (var x = 0; x <= 8; x++) {
    for (var y = 0; y <= 8; y++) {
      final p = Offset(
        mapRect.left + 1 + (mapRect.width - 2) * x / 8,
        mapRect.top + 1 + (mapRect.height - 2) * y / 8,
      );
      expect(
        painted.any((rect) => rect.contains(p)),
        true,
        reason: 'Map viewport point $p must be covered by a decoded tile',
      );
    }
  }
}

Future<void> finishTiles(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });
  await tester.pumpAndSettle();
}

void main() {
  for (final hasRover in [false, true]) {
    testWidgets(
      'first open covers full viewport without interaction, rover=$hasRover',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final tiles = LocalTiles();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ScopeMap(
                snapshot: GeoSnapshot(
                  key: 'caster|station',
                  station: const GeoPosition(45.5, 12.5),
                  rover: hasRover ? const GeoPosition(45.501, 12.501) : null,
                ),
                tileProvider: tiles,
              ),
            ),
          ),
        );
        await finishTiles(tester);
        expect(
          tiles.requested.any((t) => t.z == 3),
          false,
          reason:
              'Known station must not start at world zoom then move in onMapReady',
        );
        checkVisibleTiles(tester, tiles);
        tester.view.physicalSize = const Size(650, 1000);
        await finishTiles(tester);
        checkVisibleTiles(tester, tiles);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('late station coordinates load the full map without a gesture', (
    tester,
  ) async {
    final positions = ValueNotifier(const GeoSnapshot(key: 'caster'));
    addTearDown(positions.dispose);
    final tiles = LocalTiles();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<GeoSnapshot>(
            valueListenable: positions,
            builder: (context, snapshot, _) =>
                ScopeMap(snapshot: snapshot, tileProvider: tiles),
          ),
        ),
      ),
    );
    await finishTiles(tester);
    positions.value = const GeoSnapshot(
      key: 'caster',
      station: GeoPosition(45.5, 12.5),
    );
    await finishTiles(tester);
    checkVisibleTiles(tester, tiles);
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(map.mapController!.camera.zoom, 14);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'route transition and reopen load all visible tiles without zoom changes',
    (tester) async {
      final positions = ValueNotifier(
        const GeoSnapshot(
          key: 'caster',
          station: GeoPosition(45.5, 12.5),
          rover: GeoPosition(45.501, 12.501),
        ),
      );
      addTearDown(positions.dispose);
      final tiles = LocalTiles();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ScopeMapScreen(
                      positions: positions,
                      tileProvider: tiles,
                    ),
                  ),
                ),
                child: const Text('Open map'),
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.text('Open map'));
        await finishTiles(tester);
        checkVisibleTiles(tester, tiles);
        final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
        final zoom = map.mapController!.camera.zoom;
        positions.value = const GeoSnapshot(
          key: 'caster',
          station: GeoPosition(45.5, 12.5),
          rover: GeoPosition(45.502, 12.502),
        );
        await finishTiles(tester);
        expect(map.mapController!.camera.zoom, closeTo(zoom, 1e-8));
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    },
  );
}
