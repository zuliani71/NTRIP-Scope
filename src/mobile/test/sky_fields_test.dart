import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/sky.dart';
import 'package:ntripscope_mobile/sky_view.dart';
import 'package:ntripscope_mobile/geo.dart';
import 'package:ntripscope_mobile/rtcm.dart';
import 'package:ntripscope_mobile/main.dart';
import 'live_decoder_test.dart' as fixture;

List<int> ephemeris({int health = 0}) {
  final fields = [
    (1019, 12),
    (6, 6),
    (200, 10),
    (0, 6),
    (10, 14),
    (0, 80),
    (100, 16),
    (100, 16),
    (100000000, 32),
    (10, 16),
    (85899346, 32),
    (20, 16),
    (2702074610, 32),
    (21600, 16),
    (30, 16),
    (300000000, 32),
    (40, 16),
    (640000000, 32),
    (200, 16),
    (200000000, 32),
    (-20000, 24),
    (0, 8),
    (health, 6),
    (0, 2),
  ];
  final bits = [
    for (final (v, w) in fields)
      for (var i = w - 1; i >= 0; i--) (v >> i) & 1,
  ];
  while (bits.length % 8 != 0) {
    bits.add(0);
  }
  return [
    for (var i = 0; i < bits.length; i += 8)
      bits.sublist(i, i + 8).fold(0, (v, b) => (v << 1) | b),
  ];
}

List<int> packet(List<int> p) {
  final bytes = [0xd3, p.length >> 8, p.length & 255, ...p];
  final crc = RtcmDecoder.crc24q(bytes);
  return [...bytes, crc >> 16, (crc >> 8) & 255, crc & 255];
}

void main() {
  test(
    '1019 decode matches desktop orbital reference and rejects unhealthy/stale orbits',
    () {
      final orbit = GpsEphemeris.decode(ephemeris())!;
      expect(orbit.prn, 6);
      expect(orbit.week, 200);
      expect(orbit.toe, 345600);
      final p = orbit.position(346000, 2248)!;
      expect(p.$1, closeTo(19232676.39830575, .001));
      expect(p.$2, closeTo(14773361.252993621, .001));
      expect(p.$3, closeTo(10179897.392208623, .001));
      expect(orbit.position(360000, 2248), isNull);
      expect(GpsEphemeris.decode(ephemeris(health: 1)), isNull);
      expect(GpsEphemeris.decode([0, 0]), isNull);
      final d = RtcmDecoder()..add(packet(ephemeris()));
      expect(d.gpsOrbits.keys, [6]);
      expect(d.gpsEpoch, isNull);
      d.add(packet(fixture.msm(0, 42).payload));
      expect(d.gpsEpoch!.tow, 1.234);
      final corrupt = packet(ephemeris())..[8] ^= 1;
      final bad = RtcmDecoder()..add(corrupt);
      expect(bad.gpsOrbits, isEmpty);
    },
  );
  test('sky geometry points to zenith and excludes below horizon', () {
    const observer = GeoPosition(0, 0, 0);
    final zenith = SkyPoint.fromEcef(observer, (26378137, 0, 0))!;
    expect(zenith.elevation, closeTo(math.pi / 2, 1e-12));
    expect(SkyPoint.fromEcef(observer, (-26378137, 0, 0)), isNull);
  });
  testWidgets(
    'sky view explains missing data and renders trajectories on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const positions = GeoSnapshot(station: GeoPosition(45, 12, 100));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GpsSkyView(positions: positions, snapshot: SkySnapshot()),
          ),
        ),
      );
      expect(
        find.textContaining('Waiting for GPS ephemerides'),
        findsOneWidget,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GpsSkyView(
              positions: positions,
              snapshot: SkySnapshot(
                orbits: [GpsEphemeris.decode(ephemeris())!],
                epoch: const GpsEpoch(346000, 2248),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Fields is independently selectable and stays selected on decoder refresh',
    (tester) async {
      final updates = ValueNotifier(0);
      addTearDown(updates.dispose);
      final frames = [fixture.msm(0, 42)];
      await tester.pumpWidget(
        MaterialApp(
          home: FrameView(frames: frames, updates: updates),
        ),
      );
      await tester.tap(find.text('Fields'));
      await tester.pump();
      expect(find.textContaining('Station · 17'), findsOneWidget);
      expect(find.text('C/N₀ chart'), findsNothing);
      frames.insert(0, fixture.msm(100, 44));
      updates.value++;
      await tester.pump();
      expect(find.textContaining('Station · 17'), findsOneWidget);
      await tester.tap(find.text('Measurements'));
      await tester.pump();
      expect(find.text('44.0000'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
