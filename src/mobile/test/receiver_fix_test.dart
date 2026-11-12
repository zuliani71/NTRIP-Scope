import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/config.dart';
import 'package:ntripscope_mobile/gga.dart';
import 'package:ntripscope_mobile/receiver_fix.dart';

String sentence(String body) =>
    '\$$body*${body.codeUnits.fold(0, (v, b) => v ^ b).toRadixString(16).padLeft(2, '0')}';
String quality(int value) {
  final f = Rover(
    45.5,
    12.5,
    100,
    0,
  ).gga().split('*').first.substring(1).split(',');
  f[6] = '$value';
  return sentence(f.join(','));
}

void main() {
  final noFix = sentence('GNGGA,120000.00,,,,,0,00,99.99,,,,,,');
  test(
    'receiver quality accepts NO FIX without forwarding it or using its coordinates',
    () {
      expect(ggaQuality(noFix), 0);
      expect(validGga(noFix), false);
      expect(GgaReader().add(ascii.encode('$noFix\r\n')), isEmpty);
      for (var i = 0; i <= 8; i++) {
        expect(ggaQuality(quality(i)), i);
      }
      expect(
        ggaQuality('${quality(4).substring(0, quality(4).length - 2)}ZZ'),
        isNull,
      );
      final model = ReceiverFixModel(), now = DateTime.utc(2026, 11, 12);
      final raw = ascii.encode('${quality(4)}\r\n');
      model.add('Bluetooth', raw.sublist(0, 20), now: now);
      expect(model.status, isNull);
      model.add('TCP', ascii.encode('other\n'), now: now);
      model.add('Bluetooth', raw.sublist(20), now: now);
      expect(model.status!.label, 'RTK FIXED');
      expect(model.status!.source, 'Bluetooth');
      expect(model.status!.stale(now.add(const Duration(seconds: 6))), true);
      model.add('Bluetooth', ascii.encode('$noFix\r\n'), now: now);
      expect(model.status!.quality, 0);
      model.add(
        'Bluetooth',
        ascii.encode('\$GNGGA,broken*00\n'),
        now: now.add(const Duration(seconds: 10)),
      );
      expect(model.status!.received, now);
      model.reset();
      expect(model.status, isNull);
    },
  );
  testWidgets(
    'badge marks old fixed data stale, Stop paused and manual GGA separate',
    (tester) async {
      final status = ReceiverFixStatus(
        4,
        DateTime.now().subtract(const Duration(seconds: 10)),
        'Bluetooth',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReceiverFixBadge(status: status, active: true, manual: true),
          ),
        ),
      );
      expect(find.textContaining('STALE · RTK FIXED'), findsOneWidget);
      expect(find.textContaining('Manual GGA is sent'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReceiverFixBadge(
              status: status,
              active: false,
              manual: false,
            ),
          ),
        ),
      );
      expect(find.textContaining('PAUSED · RTK FIXED'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
