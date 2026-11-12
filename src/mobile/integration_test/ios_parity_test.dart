import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ntripscope_mobile/main.dart';
import 'package:ntripscope_mobile/config.dart';
import 'package:ntripscope_mobile/ntrip.dart';
import 'package:ntripscope_mobile/outputs.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'iPhone exposes file/TCP, BLE, confirmed configuration save, diagnostics and screen-awake controls',
    (tester) async {
      await tester.pumpWidget(const ScopeApp());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Caster host'),
        'caster.example',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.text('Save configuration'), findsOneWidget);
      await tester.tap(find.text('Save configuration'));
      await tester.pumpAndSettle();
      expect(find.text('Choose existing file'), findsOneWidget);
      expect(find.text('File name'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      final outputs = find.text('Stream outputs');
      await tester.scrollUntilVisible(
        outputs,
        250,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(outputs);
      await tester.pumpAndSettle();
      expect(find.text('Write RTCM to file'), findsOneWidget);
      expect(find.text('TCP server'), findsOneWidget);
      final ble = find.text('Bluetooth LE receiver');
      await tester.scrollUntilVisible(
        ble,
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(ble);
      await tester.pumpAndSettle();
      expect(find.text('BLE service UUID'), findsOneWidget);
      final awake = find.text('Keep screen awake while streaming');
      await tester.scrollUntilVisible(
        awake,
        180,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(awake, findsOneWidget);
      expect(find.text('Keep streaming with screen off'), findsNothing);
      await tester.tap(find.text('Live stream'));
      await tester.pumpAndSettle();
      expect(find.text('Caster → RTCM'), findsOneWidget);
      await tester.tap(find.text('RTCM3'));
      await tester.pumpAndSettle();
      expect(find.text('No valid RTCM3 frames received'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'native iOS bridge rejects unselected configuration overwrite and handles clean file/receiver close',
    (tester) async {
      const config = MethodChannel('ntripscope/configuration');
      await expectLater(
        config.invokeMethod<void>('replace', {
          'uri': 'file:///not-selected.ini',
          'name': 'not-selected.ini',
          'confirmedOverwrite': true,
          'bytes': Uint8List(1),
        }),
        throwsA(isA<PlatformException>()),
      );
      await StreamOutputs.channel.invokeMethod<void>('closeFile');
      await StreamOutputs.channel.invokeMethod<void>('closeBle');
      const lifecycle = MethodChannel('ntripscope/lifecycle');
      await lifecycle.invokeMethod<void>('setSession', {
        'active': true,
        'keepAwake': true,
      });
      await lifecycle.invokeMethod<void>('setSession', {
        'active': false,
        'keepAwake': true,
      });
    },
  );
  testWidgets(
    'iOS real sockets forward RTCM on TCP and reconnect to caster after Stop',
    (tester) async {
      final caster = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final timers = <Timer>[];
      var connections = 0;
      caster.listen((socket) {
        sockets.add(socket);
        connections++;
        var sent = false;
        socket.listen(
          (data) {
            if (!sent) {
              sent = true;
              socket.write('ICY 200 OK\r\n');
              timers.add(
                Timer.periodic(
                  const Duration(milliseconds: 30),
                  (_) => socket.add([0xd3, 0, 1, 2]),
                ),
              );
            }
          },
          onDone: socket.destroy,
          onError: (_) => socket.destroy(),
        );
      });
      addTearDown(() async {
        for (final t in timers) {
          t.cancel();
        }
        for (final s in sockets) {
          s.destroy();
        }
        await caster.close();
      });
      final config = Caster(
        host: '127.0.0.1',
        port: caster.port,
        mount: 'TEST',
      );
      for (var cycle = 0; cycle < 2; cycle++) {
        final output = StreamOutputs((error) => fail(error));
        await output.open(port: 0);
        final peer = await Socket.connect(
          InternetAddress.loopbackIPv4,
          output.tcpPort!,
        );
        final received = peer.first;
        final session = NtripSession();
        final input = session
            .stream(config)
            .listen((bytes) => unawaited(output.write(bytes)));
        expect(
          await received.timeout(const Duration(seconds: 5)),
          contains(0xd3),
        );
        session.stop();
        await input.cancel();
        await output.close();
        peer.destroy();
      }
      expect(connections, 2);
    },
  );
}
