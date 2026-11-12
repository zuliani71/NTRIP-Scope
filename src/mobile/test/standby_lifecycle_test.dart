import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/main.dart';
import 'package:ntripscope_mobile/background_streaming.dart';

void main() {
  for (final keep in [false, true]) {
    testWidgets(
      'screen-off option $keep controls actual caster connection and clean reconnection',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = const Size(430, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final calls = <String>[];
        messenger.setMockMethodCallHandler(BackgroundStreaming.channel, (
          call,
        ) async {
          calls.add(call.method);
          if (call.method == 'prepare')
            return {'batteryExempt': true, 'notifications': true};
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            BackgroundStreaming.channel,
            null,
          ),
        );
        late ServerSocket server;
        final sockets = <Socket>[], timers = <Timer>[];
        final firstClosed = Completer<void>();
        var connections = 0;
        await tester.runAsync(() async {
          server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((socket) {
            sockets.add(socket);
            final current = ++connections;
            var request = '';
            var sent = false;
            socket.listen(
              (bytes) {
                request += ascii.decode(bytes);
                if (!sent && request.contains('\r\n\r\n')) {
                  sent = true;
                  socket.write('ICY 200 OK\r\n');
                  timers.add(
                    Timer.periodic(const Duration(milliseconds: 25), (_) {
                      socket.add([1, 2, 3, 4]);
                    }),
                  );
                }
              },
              onDone: () {
                if (current == 1 && !firstClosed.isCompleted)
                  firstClosed.complete();
                socket.destroy();
              },
              onError: (_) {
                if (current == 1 && !firstClosed.isCompleted)
                  firstClosed.complete();
                socket.destroy();
              },
            );
          });
        });
        addTearDown(() async {
          for (final t in timers) {
            t.cancel();
          }
          for (final s in sockets) {
            s.destroy();
          }
          await server.close();
        });
        await tester.pumpWidget(const ScopeApp());
        await tester.pumpAndSettle();
        Finder field(String label) => find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == label,
        );
        await tester.enterText(field('Caster host'), '127.0.0.1');
        await tester.enterText(field('Port'), '${server.port}');
        await tester.enterText(field('Mountpoint'), 'TEST');
        if (keep) {
          final checkbox = find.widgetWithText(
            CheckboxListTile,
            'Keep streaming with screen off',
          );
          await tester.ensureVisible(checkbox);
          await tester.tap(checkbox);
          await tester.pumpAndSettle();
          expect(calls, contains('prepare'));
        }
        Future<void> flushUntil(bool Function() ready) async {
          for (var i = 0; i < 100 && !ready(); i++) {
            await tester.pump();
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            });
          }
          await tester.pump();
          expect(ready(), true);
        }

        final button = find.widgetWithText(FilledButton, 'Connect');
        await tester.ensureVisible(button);
        await tester.runAsync(() async {
          tester.widget<FilledButton>(button).onPressed!();
          await Future<void>.delayed(const Duration(milliseconds: 250));
        });
        await tester.pump();
        expect(connections, 1);
        if (keep) expect(calls, contains('start'));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        });
        expect(firstClosed.isCompleted, !keep);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        if (!keep) {
          await flushUntil(
            () => tester.widget<FilledButton>(button).onPressed != null,
          );
          await tester.runAsync(() async {
            tester.widget<FilledButton>(button).onPressed!();
            await Future<void>.delayed(const Duration(milliseconds: 150));
          });
          expect(connections, 2);
        } else {
          final stopped = messenger.handlePlatformMessage(
            'ntripscope/lifecycle',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('stop'),
            ),
            (_) {},
          );
          await flushUntil(() => firstClosed.isCompleted);
          await flushUntil(
            () => tester.widget<FilledButton>(button).onPressed != null,
          );
          await stopped;
          expect(calls, contains('stop'));
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
