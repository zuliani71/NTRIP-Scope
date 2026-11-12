import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ntripscope_mobile/background_streaming.dart';
import 'package:ntripscope_mobile/ntrip.dart';
import 'package:ntripscope_mobile/config.dart';
import 'package:ntripscope_mobile/outputs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test(
    'screen-off lease stop waits for pending native start and native release',
    () async {
      final started = Completer<void>(), stopped = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(BackgroundStreaming.channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'start') await started.future;
        if (call.method == 'stop') await stopped.future;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          BackgroundStreaming.channel,
          null,
        ),
      );
      final lease = BackgroundStreaming();
      final open = lease.start('VRS');
      var done = false;
      final close = lease.stop().then((_) {
        done = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['start']);
      expect(done, false);
      expect(lease.ready, false);
      started.complete();
      await open;
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['start', 'stop']);
      expect(done, false);
      expect(lease.ready, false);
      stopped.complete();
      await close;
      await lease.stop();
      expect(calls, ['start', 'stop']);
    },
  );
  test(
    'background service armed only after native startup acknowledgement',
    () async {
      messenger.setMockMethodCallHandler(
        BackgroundStreaming.channel,
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          BackgroundStreaming.channel,
          null,
        ),
      );
      final lease = BackgroundStreaming();
      await lease.start('VRS');
      expect(lease.ready, true);
      await lease.stop();
      expect(lease.ready, false);
    },
  );
  test(
    'full suspend upgrades a retained Bluetooth Stop and all callers await cleanup',
    () async {
      final released = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('ntripscope/bluetooth'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(StreamOutputs.channel, (call) async {
        calls.add(call.method);
        if (call.method == 'closeBluetooth') await released.future;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('ntripscope/bluetooth'),
          null,
        ),
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(StreamOutputs.channel, null),
      );
      final outputs = StreamOutputs((_) {});
      await outputs.open(bluetooth: '00:00:00:00:00:00');
      await outputs.close(keepBluetooth: true);
      expect(calls, isNot(contains('closeBluetooth')));
      var firstDone = false, secondDone = false;
      final first = outputs.close().then((_) {
        firstDone = true;
      });
      final second = outputs.close().then((_) {
        secondDone = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(firstDone, false);
      expect(secondDone, false);
      expect(calls.where((c) => c == 'closeBluetooth').length, 1);
      released.complete();
      await Future.wait([first, second]);
      expect(firstDone && secondDone, true);
    },
  );
  test(
    'suspend cancels a pending file open without a late close touching a new session',
    () async {
      final opened = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(StreamOutputs.channel, (call) async {
        calls.add(call.method);
        if (call.method == 'openFile') await opened.future;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(StreamOutputs.channel, null),
      );
      final outputs = StreamOutputs((_) {});
      Object? failure;
      final opening = outputs.open(file: 'content://test/capture').catchError((
        Object e,
      ) {
        failure = e;
      });
      await Future<void>.delayed(Duration.zero);
      await outputs.close();
      await opening.timeout(const Duration(seconds: 1));
      expect(failure, isA<StateError>());
      expect(calls.where((c) => c == 'closeFile').length, 1);
      opened.complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c == 'closeFile').length, 1);
    },
  );
  test(
    'suspend interrupts a pending file write and suppresses later Bluetooth writes',
    () async {
      final written = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('ntripscope/bluetooth'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(StreamOutputs.channel, (call) async {
        calls.add(call.method);
        if (call.method == 'writeFile') await written.future;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(StreamOutputs.channel, null),
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('ntripscope/bluetooth'),
          null,
        ),
      );
      final outputs = StreamOutputs((_) {});
      await outputs.open(
        file: 'content://test/capture',
        bluetooth: '00:00:00:00:00:00',
      );
      final writing = outputs.write(Uint8List.fromList([0xd3, 0, 255]));
      await Future<void>.delayed(Duration.zero);
      expect(calls, contains('writeFile'));
      await outputs.close();
      await writing.timeout(const Duration(seconds: 1));
      written.complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isNot(contains('writeBluetooth')));
    },
  );
  for (final response in [false, true]) {
    test(
      'Stop closes caster during ${response ? 'active stream' : 'silent header'} and immediate retry succeeds',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(server.close);
        final received = Completer<void>(), closed = Completer<void>();
        var connections = 0;
        final worker = server.listen((socket) {
          final current = ++connections;
          var request = '';
          var sent = false;
          socket.listen(
            (bytes) {
              request += ascii.decode(bytes);
              if (!sent && request.contains('\r\n\r\n')) {
                sent = true;
                if (current == 1) {
                  if (response) socket.write('ICY 200 OK\r\n');
                  received.complete();
                } else {
                  socket.add([...ascii.encode('ICY 200 OK\r\n'), 0xd3, 0, 255]);
                  socket.close();
                }
              }
            },
            onDone: () {
              if (current == 1 && !closed.isCompleted) closed.complete();
              socket.destroy();
            },
            onError: (_) {
              if (current == 1 && !closed.isCompleted) closed.complete();
              socket.destroy();
            },
          );
        });
        addTearDown(worker.cancel);
        final config = Caster(
          host: '127.0.0.1',
          port: server.port,
          mount: 'TEST',
          version: 1,
        );
        final session = NtripSession();
        addTearDown(session.stop);
        final finished = Completer<void>();
        session
            .stream(config)
            .listen(
              (_) {},
              onDone: () {
                if (!finished.isCompleted) finished.complete();
              },
              onError: (_) {
                if (!finished.isCompleted) finished.complete();
              },
            );
        await received.future.timeout(const Duration(seconds: 2));
        session.stop(releaseReceiver: true);
        session.stop();
        expect(session.releaseReceiverOnStop, true);
        await closed.future.timeout(const Duration(seconds: 2));
        await finished.future.timeout(const Duration(seconds: 2));
        final retry = NtripSession();
        addTearDown(retry.stop);
        expect(
          await retry
              .stream(config)
              .expand((b) => b)
              .toList()
              .timeout(const Duration(seconds: 2)),
          [0xd3, 0, 255],
        );
        expect(connections, 2);
      },
    );
  }
}
