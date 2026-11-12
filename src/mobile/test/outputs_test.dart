import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:ntripscope_mobile/outputs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('monitors raw TCP receiver input before any RTCM is sent', () async {
    final observed = Completer<List<int>>();
    String? source;
    final outputs = StreamOutputs(
      (message) => fail(message),
      onMonitorData: (name, bytes) {
        source = name;
        if (!observed.isCompleted) observed.complete(bytes);
      },
    );
    addTearDown(outputs.close);
    await outputs.open(port: 0);
    final peer = await Socket.connect(
      InternetAddress.loopbackIPv4,
      outputs.tcpPort!,
    );
    addTearDown(peer.destroy);
    final raw = [36, 71, 80, 71, 71, 65, 44, 13, 10, 0, 255];
    peer.add(raw);
    await peer.flush();
    expect(await observed.future.timeout(const Duration(seconds: 2)), raw);
    expect(source, startsWith('TCP · '));
  });

  test(
    'Stop retains Bluetooth, drops late input and allows a new session',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('ntripscope/bluetooth'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(StreamOutputs.channel, (call) async {
        calls.add(call.method);
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
      var received = 0;
      final first = StreamOutputs(
        (message) => fail(message),
        onReceiverData: (_) => received++,
      );
      await first.open(bluetooth: '00:00:00:00:00:00');
      await first.close(keepBluetooth: true);
      expect(calls, isNot(contains('closeBluetooth')));
      final second = StreamOutputs(
        (message) => fail(message),
        onReceiverData: (_) => received++,
      );
      addTearDown(second.close);
      await second.open(bluetooth: '00:00:00:00:00:00');
      await messenger.handlePlatformMessage(
        'ntripscope/bluetooth',
        const StandardMethodCodec().encodeSuccessEnvelope(
          Uint8List.fromList([36, 71, 80, 13, 10]),
        ),
        (_) {},
      );
      expect(received, 1);
      await second.close();
      expect(calls.last, 'closeBluetooth');
    },
  );

  test('sends identical RTCM bytes to file, TCP and Bluetooth', () async {
    final calls = <String, Object?>{};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('ntripscope/bluetooth'),
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('ntripscope/bluetooth'),
        null,
      ),
    );
    messenger.setMockMethodCallHandler(StreamOutputs.channel, (call) async {
      calls[call.method] = call.arguments;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(StreamOutputs.channel, null),
    );
    final incoming = Completer<List<int>>();
    final outputs = StreamOutputs(
      (message) => fail(message),
      onMonitorData: (source, data) {
        expect(source, contains('Bluetooth'));
        if (!incoming.isCompleted) incoming.complete(data);
      },
    );
    addTearDown(outputs.close);
    await outputs.open(
      file: 'content://test/corrections',
      port: 0,
      bluetooth: '00:00:00:00:00:00',
    );
    await messenger.handlePlatformMessage(
      'ntripscope/bluetooth',
      const StandardMethodCodec().encodeSuccessEnvelope(
        Uint8List.fromList([36, 71, 80, 13, 10, 0, 255]),
      ),
      (_) {},
    );
    expect(await incoming.future.timeout(const Duration(seconds: 2)), [
      36,
      71,
      80,
      13,
      10,
      0,
      255,
    ]);
    final peer = await Socket.connect(
      InternetAddress.loopbackIPv4,
      outputs.tcpPort!,
    );
    addTearDown(peer.destroy);
    final received = peer.first;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final bytes = Uint8List.fromList([0xd3, 0, 2, 0xff, 0, 13, 10, 0]);
    await outputs.write(bytes);
    expect(await received.timeout(const Duration(seconds: 2)), bytes);
    expect(calls['writeFile'], bytes);
    expect(calls['writeBluetooth'], bytes);
    await outputs.close();
    expect(calls.keys, containsAll(['closeFile', 'closeBluetooth']));
  });
}
